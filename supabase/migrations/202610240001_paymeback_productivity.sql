-- Productivity, private files, and borrower payment requests for PayMeBack.
-- Apply after 202610210001_paymeback_core.sql.

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  loan_id uuid references public.loans(id) on delete cascade,
  title text not null check (length(btrim(title)) between 1 and 160),
  details text not null default '' check (length(details) <= 2000),
  due_date date,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.notes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  loan_id uuid references public.loans(id) on delete cascade,
  title text not null default '' check (length(title) <= 160),
  content text not null check (length(btrim(content)) between 1 and 10000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.loan_documents (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  loan_id uuid not null references public.loans(id) on delete cascade,
  storage_path text not null unique,
  file_name text not null check (length(file_name) between 1 and 255),
  mime_type text not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  size_bytes bigint not null check (size_bytes between 1 and 10485760),
  created_at timestamptz not null default now(),
  check (storage_path like (owner_id::text || '/' || loan_id::text || '/%'))
);

create table if not exists public.loan_follow_ups (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  loan_id uuid not null references public.loans(id) on delete cascade,
  sent_at timestamptz not null default now(),
  method text not null default 'manual' check (method = 'manual'),
  note text not null default '' check (length(note) <= 500)
);

alter table public.share_links
  add column if not exists allow_payment_submissions boolean not null default false;

create table if not exists public.borrower_payment_submissions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  loan_id uuid not null references public.loans(id) on delete cascade,
  share_link_id uuid not null references public.share_links(id) on delete cascade,
  payment_date date not null default current_date,
  amount_cents bigint not null check (amount_cents between 1 and 9007199254740991),
  note text not null default '' check (length(note) <= 300),
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  check (reviewed_at is null or status <> 'pending')
);

create index if not exists tasks_owner_due_idx on public.tasks(owner_id, due_date, completed_at);
create index if not exists notes_owner_updated_idx on public.notes(owner_id, updated_at desc);
create index if not exists documents_loan_created_idx on public.loan_documents(loan_id, created_at desc);
create index if not exists follow_ups_loan_sent_idx on public.loan_follow_ups(loan_id, sent_at desc);
create index if not exists borrower_submissions_owner_status_idx
  on public.borrower_payment_submissions(owner_id, status, created_at desc);
create unique index if not exists borrower_submissions_one_pending_per_link_idx
  on public.borrower_payment_submissions(share_link_id) where status = 'pending';

alter table public.tasks enable row level security;
alter table public.notes enable row level security;
alter table public.loan_documents enable row level security;
alter table public.loan_follow_ups enable row level security;
alter table public.borrower_payment_submissions enable row level security;

drop policy if exists "Owners manage their tasks" on public.tasks;
create policy "Owners manage their tasks" on public.tasks
  for all to authenticated using (owner_id = (select auth.uid()))
  with check (
    owner_id = (select auth.uid())
    and (loan_id is null or exists (
      select 1 from public.loans l where l.id = loan_id and l.owner_id = (select auth.uid())
    ))
  );

drop policy if exists "Owners manage their notes" on public.notes;
create policy "Owners manage their notes" on public.notes
  for all to authenticated using (owner_id = (select auth.uid()))
  with check (
    owner_id = (select auth.uid())
    and (loan_id is null or exists (
      select 1 from public.loans l where l.id = loan_id and l.owner_id = (select auth.uid())
    ))
  );

drop policy if exists "Owners manage their loan documents" on public.loan_documents;
create policy "Owners manage their loan documents" on public.loan_documents
  for all to authenticated using (owner_id = (select auth.uid()))
  with check (
    owner_id = (select auth.uid())
    and exists (select 1 from public.loans l where l.id = loan_id and l.owner_id = (select auth.uid()))
    and storage_path like (select auth.uid())::text || '/' || loan_id::text || '/%'
  );

drop policy if exists "Owners manage their loan follow-ups" on public.loan_follow_ups;
create policy "Owners manage their loan follow-ups" on public.loan_follow_ups
  for all to authenticated using (owner_id = (select auth.uid()))
  with check (
    owner_id = (select auth.uid())
    and exists (select 1 from public.loans l where l.id = loan_id and l.owner_id = (select auth.uid()))
  );

drop policy if exists "Owners read their borrower payment submissions" on public.borrower_payment_submissions;
create policy "Owners read their borrower payment submissions" on public.borrower_payment_submissions
  for select to authenticated using (owner_id = (select auth.uid()));

grant select, insert, update, delete on public.tasks, public.notes to authenticated;
grant select, insert, delete on public.loan_documents, public.loan_follow_ups to authenticated;
grant select on public.borrower_payment_submissions to authenticated;
revoke all on public.tasks, public.notes, public.loan_documents, public.loan_follow_ups,
  public.borrower_payment_submissions from public, anon;
revoke insert, update, delete on public.borrower_payment_submissions from authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('paymeback-loan-documents', 'paymeback-loan-documents', false, 10485760,
  array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Owners read private PayMeBack loan documents" on storage.objects;
create policy "Owners read private PayMeBack loan documents" on storage.objects
  for select to authenticated using (
    bucket_id = 'paymeback-loan-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and exists (
      select 1 from public.loans l
      where l.id::text = (storage.foldername(name))[2] and l.owner_id = (select auth.uid())
    )
  );

drop policy if exists "Owners upload private PayMeBack loan documents" on storage.objects;
create policy "Owners upload private PayMeBack loan documents" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'paymeback-loan-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and exists (
      select 1 from public.loans l
      where l.id::text = (storage.foldername(name))[2] and l.owner_id = (select auth.uid())
    )
  );

drop policy if exists "Owners delete private PayMeBack loan documents" on storage.objects;
create policy "Owners delete private PayMeBack loan documents" on storage.objects
  for delete to authenticated using (
    bucket_id = 'paymeback-loan-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and exists (
      select 1 from public.loans l
      where l.id::text = (storage.foldername(name))[2] and l.owner_id = (select auth.uid())
    )
  );

create or replace function public.submit_shared_payment(
  p_token text,
  p_amount_cents bigint,
  p_payment_date date default current_date,
  p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link public.share_links%rowtype;
  v_loan public.loans%rowtype;
  v_paid bigint;
  v_forgiven bigint;
  v_pending bigint;
  v_recent_count integer;
  v_submission_id uuid;
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then
    raise exception 'This payment link is invalid.';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'Enter a payment amount greater than zero.';
  end if;
  if p_payment_date is not null and p_payment_date > current_date then
    raise exception 'Payment date cannot be in the future.';
  end if;
  if length(coalesce(p_note, '')) > 300 then raise exception 'Payment note is too long.'; end if;

  select sl.* into v_link
  from public.share_links sl
  where sl.token_hash = pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p_token, 'UTF8')), 'hex')
    and sl.allow_payment_submissions
    and sl.revoked_at is null
    and (sl.expires_at is null or sl.expires_at > pg_catalog.now());
  if not found then raise exception 'Payment submissions are not enabled for this link.'; end if;

  select count(*) into v_recent_count
  from public.borrower_payment_submissions s
  where s.share_link_id = v_link.id
    and s.created_at > pg_catalog.now() - interval '1 day';
  if v_recent_count >= 5 then raise exception 'Too many payment reports were sent from this link. Try again later.'; end if;

  select l.* into v_loan from public.loans l where l.id = v_link.loan_id for update;
  if not found or v_loan.status <> 'active' then raise exception 'This loan is not accepting payment submissions.'; end if;

  select coalesce(sum(p.amount_cents), 0) into v_paid
  from public.payments p where p.loan_id = v_loan.id;
  select coalesce(sum(a.amount_cents), 0) into v_forgiven
  from public.loan_adjustments a where a.loan_id = v_loan.id;
  select coalesce(sum(s.amount_cents), 0) into v_pending
  from public.borrower_payment_submissions s where s.loan_id = v_loan.id and s.status = 'pending';
  if p_amount_cents > v_loan.initial_amount_cents - v_paid - v_forgiven - v_pending then
    raise exception 'This amount is higher than the available remaining balance.';
  end if;

  insert into public.borrower_payment_submissions (
    owner_id, loan_id, share_link_id, payment_date, amount_cents, note
  ) values (
    v_loan.owner_id, v_loan.id, v_link.id, coalesce(p_payment_date, current_date), p_amount_cents, left(coalesce(p_note, ''), 300)
  ) returning id into v_submission_id;
  return v_submission_id;
end;
$$;

create or replace function public.review_shared_payment(p_submission_id uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_submission public.borrower_payment_submissions%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select s.* into v_submission
  from public.borrower_payment_submissions s
  where s.id = p_submission_id and s.owner_id = auth.uid()
  for update;
  if not found then raise exception 'Payment submission not found.'; end if;
  if v_submission.status <> 'pending' then raise exception 'This submission has already been reviewed.'; end if;

  if p_approve then
    perform public.record_loan_payment(
      v_submission.loan_id, v_submission.payment_date, v_submission.amount_cents,
      coalesce(nullif(v_submission.note, ''), 'Borrower-submitted payment')
    );
    update public.borrower_payment_submissions
    set status = 'confirmed', reviewed_at = pg_catalog.now()
    where id = v_submission.id;
  else
    update public.borrower_payment_submissions
    set status = 'rejected', reviewed_at = pg_catalog.now()
    where id = v_submission.id;
  end if;
end;
$$;

create or replace function public.get_shared_statement(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_statement jsonb;
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then return null; end if;

  select jsonb_build_object(
    'borrowerName', l.borrower_name,
    'reason', l.reason,
    'startDate', l.start_date,
    'targetDueDate', l.target_due_date,
    'initialAmountCents', l.initial_amount_cents,
    'repaymentType', l.repayment_type,
    'installmentAmountCents', l.installment_amount_cents,
    'installmentCount', l.installment_count,
    'status', l.status,
    'allowPaymentSubmissions', sl.allow_payment_submissions,
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object('date', p.payment_date, 'amountCents', p.amount_cents, 'note', p.note)
        order by p.payment_date desc, p.created_at desc)
      from public.payments p where p.loan_id = l.id
    ), '[]'::jsonb),
    'adjustments', coalesce((
      select jsonb_agg(jsonb_build_object('date', a.adjustment_date, 'amountCents', a.amount_cents, 'note', a.note, 'kind', a.kind)
        order by a.adjustment_date desc, a.created_at desc)
      from public.loan_adjustments a where a.loan_id = l.id
    ), '[]'::jsonb),
    'installments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'number', i.installment_number, 'dueDate', i.due_date, 'amountCents', i.amount_due_cents,
        'paidCents', i.paid_cents, 'forgivenCents', i.forgiven_cents
      ) order by i.installment_number)
      from public.installments i where i.loan_id = l.id and i.is_current
    ), '[]'::jsonb),
    'paymentOptions', jsonb_build_object('venmo', coalesce(s.venmo, ''), 'cashapp', coalesce(s.cashapp, ''), 'zelle', coalesce(s.zelle, ''))
  )
  into v_statement
  from public.share_links sl
  join public.loans l on l.id = sl.loan_id
  left join public.user_settings s on s.user_id = l.owner_id
  where sl.token_hash = pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p_token, 'UTF8')), 'hex')
    and sl.revoked_at is null
    and (sl.expires_at is null or sl.expires_at > pg_catalog.now());
  return v_statement;
end;
$$;

revoke all on function public.submit_shared_payment(text, bigint, date, text) from public;
revoke all on function public.review_shared_payment(uuid, boolean) from public, anon;
grant execute on function public.submit_shared_payment(text, bigint, date, text) to anon, authenticated;
grant execute on function public.review_shared_payment(uuid, boolean) to authenticated;
