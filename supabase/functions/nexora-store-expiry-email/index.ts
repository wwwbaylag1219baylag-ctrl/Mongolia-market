import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function escapeHtml(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[char] ?? char);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  const expectedSecret = Deno.env.get("cron_secret");
  const suppliedSecret = req.headers.get("x-cron-secret");
  if (!expectedSecret || !suppliedSecret || suppliedSecret !== expectedSecret) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const resendKey = Deno.env.get("resend_api_key");
  const fromEmail = Deno.env.get("resend_from_email");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!resendKey || !fromEmail || !supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: "Email sender is not configured" }, 503);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: pending, error } = await supabase
    .from("nexora_store_notifications")
    .select("id,user_id,title,message")
    .is("email_sent_at", null)
    .order("created_at", { ascending: true })
    .limit(100);

  if (error) {
    console.error("Failed to load pending notifications:", error.message);
    return jsonResponse({ error: "Could not load pending notifications" }, 500);
  }

  let sent = 0;
  let failed = 0;

  for (const notice of pending ?? []) {
    try {
      const { data: userResult, error: userError } =
        await supabase.auth.admin.getUserById(notice.user_id);
      const email = userResult?.user?.email;

      if (userError || !email) {
        const reason = userError?.message ?? "User email not found";
        const update = await supabase
          .from("nexora_store_notifications")
          .update({ email_error: reason })
          .eq("id", notice.id);
        if (update.error) console.error("Could not record missing-email error:", update.error.message);
        failed++;
        continue;
      }

      const safeTitle = escapeHtml(notice.title);
      const safeMessage = escapeHtml(notice.message);
      const html = `<div style="font-family:Arial,sans-serif;line-height:1.6;color:#222">
        <h2>${safeTitle}</h2>
        <p>${safeMessage}</p>
        <p>Дэлгүүрийн эрхээ сунгахын тулд Угалз.мн хэрэглэгчийн самбарт нэвтэрнэ үү.</p>
      </div>`;

      const response = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${resendKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          from: fromEmail,
          to: [email],
          subject: String(notice.title ?? "Угалз.мн сануулга"),
          html,
        }),
        signal: AbortSignal.timeout(15000),
      });

      if (!response.ok) {
        const detail = (await response.text()).slice(0, 1000);
        const update = await supabase
          .from("nexora_store_notifications")
          .update({ email_error: `Resend HTTP ${response.status}: ${detail}` })
          .eq("id", notice.id);
        if (update.error) console.error("Could not record Resend error:", update.error.message);
        failed++;
        continue;
      }

      const update = await supabase
        .from("nexora_store_notifications")
        .update({ email_sent_at: new Date().toISOString(), email_error: null })
        .eq("id", notice.id);

      if (update.error) {
        console.error("Email accepted but sent status could not be saved:", update.error.message);
        failed++;
        continue;
      }
      sent++;
    } catch (err) {
      const reason = err instanceof Error ? err.message : "Unknown email delivery error";
      const update = await supabase
        .from("nexora_store_notifications")
        .update({ email_error: reason.slice(0, 1000) })
        .eq("id", notice.id);
      if (update.error) console.error("Could not record delivery error:", update.error.message);
      failed++;
    }
  }

  return jsonResponse({
    scanned: pending?.length ?? 0,
    sent,
    failed,
    message: "Batch processed. Failed messages remain eligible for retry.",
  });
});
