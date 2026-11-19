drop policy if exists "Supplier resubmits rejected registration" on public.market_suppliers;
create policy "Supplier resubmits rejected registration"
on public.market_suppliers
for update to authenticated
using (owner_id=(select auth.uid()) and status in ('rejected','pending'))
with check (owner_id=(select auth.uid()) and status='pending');
