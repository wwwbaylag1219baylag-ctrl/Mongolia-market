import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405, headers: cors });

  const expectedSecret = Deno.env.get("CRON_SECRET");
  const suppliedSecret = req.headers.get("x-cron-secret");
  if (!expectedSecret || !suppliedSecret || suppliedSecret !== expectedSecret) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: { ...cors, "Content-Type": "application/json" } });
  }

  const resendKey = Deno.env.get("RESEND_API_KEY");
  const fromEmail = Deno.env.get("RESEND_FROM_EMAIL");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!resendKey || !fromEmail || !supabaseUrl || !serviceRoleKey) {
    return new Response(JSON.stringify({ error: "Email sender is not configured" }), { status: 503, headers: { ...cors, "Content-Type": "application/json" } });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: pending, error } = await supabase.from("nexora_store_notifications")
    .select("id,user_id,title,message").is("email_sent_at", null)
    .order("created_at", { ascending: true }).limit(100);
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });

  let sent = 0;
  let failed = 0;
  for (const notice of pending ?? []) {
    const { data: userResult, error: userError } = await supabase.auth.admin.getUserById(notice.user_id);
    const email = userResult?.user?.email;
    if (userError || !email) {
      await supabase.from("nexora_store_notifications").update({ email_error: userError?.message ?? "User email not found" }).eq("id", notice.id);
      failed++;
      continue;
    }
    const html = `<div style="font-family:Arial,sans-serif;line-height:1.6;color:#222"><h2>${notice.title}</h2><p>${notice.message}</p><p>Дэлгүүрийн эрхээ сунгахын тулд NEXORA хэрэглэгчийн самбарт нэвтэрнэ үү.</p></div>`;
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: fromEmail, to: [email], subject: notice.title, html }),
    });
    if (!response.ok) {
      await supabase.from("nexora_store_notifications").update({ email_error: (await response.text()).slice(0, 1000) }).eq("id", notice.id);
      failed++;
      continue;
    }
    await supabase.from("nexora_store_notifications").update({ email_sent_at: new Date().toISOString(), email_error: null }).eq("id", notice.id);
    sent++;
  }
  return new Response(JSON.stringify({ scanned: pending?.length ?? 0, sent, failed }), { headers: { ...cors, "Content-Type": "application/json" } });
});
