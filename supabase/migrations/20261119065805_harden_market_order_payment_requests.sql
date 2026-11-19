create unique index if not exists market_order_payment_one_pending_per_order
on public.market_order_payment_requests(order_id)
where status='pending_review';

create index if not exists market_order_payment_requests_buyer_created_idx
on public.market_order_payment_requests(buyer_id,created_at desc);

drop policy if exists "Buyers submit own order payment requests" on public.market_order_payment_requests;
create policy "Buyers submit own order payment requests"
on public.market_order_payment_requests
for insert to authenticated
with check (
  buyer_id=(select auth.uid())
  and status='pending_review'
  and reviewed_by is null
  and reviewed_at is null
  and split_part(receipt_path,'/',1)=(select auth.uid())::text
  and exists (
    select 1 from storage.objects o
    where o.bucket_id='payment-receipts' and o.name=receipt_path
  )
  and exists (
    select 1 from public.market_orders o
    where o.id=market_order_payment_requests.order_id
      and o.buyer_id=(select auth.uid())
      and o.status='pending_payment'
      and o.payment_status='unpaid'
      and o.total_amount=market_order_payment_requests.amount
  )
  and exists (
    select 1 from public.bank_accounts b
    where b.id=market_order_payment_requests.bank_account_id and b.is_active=true
  )
);
