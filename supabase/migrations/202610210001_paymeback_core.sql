-- PayMeBack hosted account schema.
-- Apply this migration to a Supabase project before configuring the static frontend.

create table if not exists public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  venmo text not null default '',
  cashapp text not null default '',
  zelle text not null default '',
  theme text not null default 'light' check (theme in ('light', 'dark')),
  updated_at timestamptz not null default now()
);

create table if not exists public.loans (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  borrower_name text not null check (length(btrim(borrower_name)) between 1 and 120),
  borrower_contact text not null default '',
  start_date date not null default current_date,
  target_due_date date,
  initial_amount_cents bigint not null check (initial_amount_cents between 1 and 9007199254740991),
  reason text not null default '',
  repayment_type text not null default 'flexible'
    check (repayment_type in ('one_time', 'flexible', 'installment')),
  installment_amount_cents bigint,
  installment_count integer,
  first_due_date date,
  status text not null default 'active'
    check (status in ('active', 'paid_in_full', 'archived')),
  legacy_id text,
  last_plan_agreed_by uuid references auth.users(id) on delete set null,
  last_plan_agreed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (repayment_type = 'installment'
      and installment_amount_cents is not null
      and installment_amount_cents between 1 and 9007199254740991
      and installment_count is not null
      and installment_count between 1 and 600
      and first_due_date is not null
      and installment_amount_cents::numeric * (installment_count - 1) < initial_amount_cents)
    or
    (repayment_type <> 'installment'
      and installment_amount_cents is null
      and installment_count is null
      and first_due_date is null)
  )
);
create unique index if not exists loans_owner_legacy_id_idx
  on public.loans(owner_id, legacy_id) where legacy_id is not null;

create table if not exists public.installments (
  id uuid primary key default gen_random_uuid(),
  loan_id uuid not null references public.loans(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  installment_number integer not null check (installment_number > 0),
  due_date date,
  amount_due_cents bigint not null check (amount_due_cents between 1 and 9007199254740991),
  paid_cents bigint not null default 0 check (paid_cents >= 0 and paid_cents <= amount_due_cents),
  forgiven_cents bigint not null default 0 check (forgiven_cents >= 0),
  plan_version integer not null default 1,
  is_current boolean not null default true,
  created_at timestamptz not null default now(),
  unique (loan_id, plan_version, installment_number),
  check (paid_cents + forgiven_cents <= amount_due_cents)
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  loan_id uuid not null references public.loans(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  payment_date date not null default current_date,
  amount_cents bigint not null check (amount_cents between 1 and 9007199254740991),
  note text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.loan_adjustments (
  id uuid primary key default gen_random_uuid(),
  loan_id uuid not null references public.loans(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  adjustment_date date not null default current_date,
  amount_cents bigint not null check (amount_cents between 1 and 9007199254740991),
  kind text not null check (kind = 'forgiveness'),
  note text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.loan_plan_history (
  id bigint generated always as identity primary key,
  loan_id uuid not null references public.loans(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  previous_plan jsonb not null,
  new_plan jsonb not null,
  changed_by uuid references auth.users(id) on delete set null,
  borrower_agreement_attested boolean not null default false,
  changed_at timestamptz not null default now()
);

create table if not exists public.share_links (
  id uuid primary key default gen_random_uuid(),
  loan_id uuid not null references public.loans(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  token_hash text not null unique check (token_hash ~ '^[a-f0-9]{64}$'),
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists loans_owner_status_idx on public.loans(owner_id, status);
create index if not exists installments_loan_due_idx on public.installments(loan_id, due_date, installment_number);
create index if not exists payments_loan_date_idx on public.payments(loan_id, payment_date desc);
create index if not exists adjustments_loan_date_idx on public.loan_adjustments(loan_id, adjustment_date desc);
create index if not exists shares_owner_loan_idx on public.share_links(owner_id, loan_id, created_at desc);

alter table public.user_settings enable row level security;
alter table public.loans enable row level security;
alter table public.installments enable row level security;
alter table public.payments enable row level security;
alter table public.loan_adjustments enable row level security;
alter table public.loan_plan_history enable row level security;
alter table public.share_links enable row level security;

drop policy if exists "Owners manage their settings" on public.user_settings;
create policy "Owners manage their settings" on public.user_settings
  for all to authenticated using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "Owners manage their loans" on public.loans;
create policy "Owners manage their loans" on public.loans
  for all to authenticated using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

drop policy if exists "Owners read their installments" on public.installments;
create policy "Owners read their installments" on public.installments
  for select to authenticated using (owner_id = (select auth.uid()));

drop policy if exists "Owners read their payments" on public.payments;
create policy "Owners read their payments" on public.payments
  for select to authenticated using (owner_id = (select auth.uid()));

drop policy if exists "Owners read their adjustments" on public.loan_adjustments;
create policy "Owners read their adjustments" on public.loan_adjustments
  for select to authenticated using (owner_id = (select auth.uid()));

drop policy if exists "Owners read their plan history" on public.loan_plan_history;
create policy "Owners read their plan history" on public.loan_plan_history
  for select to authenticated using (owner_id = (select auth.uid()));

drop policy if exists "Owners manage their share links" on public.share_links;
create policy "Owners manage their share links" on public.share_links
  for all to authenticated using (owner_id = (select auth.uid()))
  with check (
    owner_id = (select auth.uid())
    and exists (
      select 1 from public.loans l
      where l.id = loan_id and l.owner_id = (select auth.uid())
    )
  );

grant select, insert, update, delete on public.user_settings to authenticated;
grant select, insert, delete on public.loans to authenticated;
grant update (status) on public.loans to authenticated;
grant select on public.installments, public.payments, public.loan_adjustments, public.loan_plan_history to authenticated;
grant select, insert, update, delete on public.share_links to authenticated;
revoke all on public.user_settings, public.loans, public.installments, public.payments,
  public.loan_adjustments, public.loan_plan_history, public.share_links from anon;
revoke update on public.loans from authenticated;
grant update (status) on public.loans to authenticated;
revoke insert, update, delete on public.installments, public.payments, public.loan_adjustments,
  public.loan_plan_history from authenticated;

create or replace function public.paymeback_sync_installments()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_index integer;
  v_due date;
  v_amount bigint;
  v_last_amount bigint;
  v_has_payments boolean;
  v_received bigint;
  v_forgiven bigint;
  v_schedule_balance bigint;
begin
  if tg_op = 'UPDATE' then
    if row(old.initial_amount_cents, old.repayment_type, old.installment_amount_cents,
      old.installment_count, old.first_due_date, old.target_due_date)
      is not distinct from row(new.initial_amount_cents, new.repayment_type,
      new.installment_amount_cents, new.installment_count, new.first_due_date, new.target_due_date) then
      return new;
    end if;

    select exists(select 1 from public.payments p where p.loan_id = old.id)
      or exists(select 1 from public.loan_adjustments a where a.loan_id = old.id)
      into v_has_payments;
    if v_has_payments and old.initial_amount_cents <> new.initial_amount_cents then
      raise exception 'The original principal cannot be changed after a payment or forgiveness adjustment.';
    end if;

    select coalesce(sum(p.amount_cents), 0) into v_received
    from public.payments p where p.loan_id = old.id;
    select coalesce(sum(a.amount_cents), 0) into v_forgiven
    from public.loan_adjustments a where a.loan_id = old.id;
    v_schedule_balance := greatest(0, new.initial_amount_cents - v_received - v_forgiven);

    insert into public.loan_plan_history (
      loan_id, owner_id, previous_plan, new_plan, changed_by, borrower_agreement_attested
    )
    values (
      old.id,
      old.owner_id,
      jsonb_build_object(
        'initial_amount_cents', old.initial_amount_cents,
        'repayment_type', old.repayment_type,
        'installment_amount_cents', old.installment_amount_cents,
        'installment_count', old.installment_count,
        'first_due_date', old.first_due_date,
        'remaining_cents', v_schedule_balance
      ),
      jsonb_build_object(
        'initial_amount_cents', new.initial_amount_cents,
        'repayment_type', new.repayment_type,
        'installment_amount_cents', new.installment_amount_cents,
        'installment_count', new.installment_count,
        'first_due_date', new.first_due_date,
        'remaining_cents', v_schedule_balance
      ),
      auth.uid(),
      new.last_plan_agreed_at is not null and new.last_plan_agreed_by = auth.uid()
    );
    update public.installments set is_current = false where loan_id = old.id and is_current;
    select coalesce(max(i.plan_version), 0) + 1 into v_version
    from public.installments i where i.loan_id = old.id;
  else
    v_schedule_balance := new.initial_amount_cents;
    v_version := 1;
  end if;

  if v_schedule_balance > 0 and new.repayment_type = 'installment' then
    if new.installment_amount_cents::numeric * (new.installment_count - 1) >= v_schedule_balance then
      raise exception 'The revised installment amount and count do not fit the outstanding balance.';
    end if;
    v_last_amount := v_schedule_balance -
      (new.installment_amount_cents * (new.installment_count - 1));
    for v_index in 1..new.installment_count loop
      v_due := (new.first_due_date + ((v_index - 1) * interval '1 month'))::date;
      v_amount := case when v_index = new.installment_count
        then v_last_amount else new.installment_amount_cents end;
      insert into public.installments (
        loan_id, owner_id, installment_number, due_date, amount_due_cents, plan_version, is_current
      ) values (new.id, new.owner_id, v_index, v_due, v_amount, v_version, true);
    end loop;
  elsif v_schedule_balance > 0 and new.repayment_type = 'one_time' then
    insert into public.installments (
      loan_id, owner_id, installment_number, due_date, amount_due_cents, plan_version, is_current
    ) values (new.id, new.owner_id, 1, new.target_due_date, v_schedule_balance, v_version, true);
  end if;

  return new;
end;
$$;

create or replace function public.save_loan(
  p_loan_id uuid,
  p_borrower_name text,
  p_borrower_contact text,
  p_start_date date,
  p_target_due_date date,
  p_initial_amount_cents bigint,
  p_reason text,
  p_repayment_type text,
  p_installment_amount_cents bigint,
  p_installment_count integer,
  p_first_due_date date,
  p_agreement_attested boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_loan public.loans%rowtype;
  v_has_activity boolean;
  v_plan_changed boolean;
  v_received bigint;
  v_forgiven bigint;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_loan_id is null then raise exception 'Loan identifier is required'; end if;

  select l.* into v_loan
  from public.loans l
  where l.id = p_loan_id and l.owner_id = auth.uid()
  for update;
  if not found then raise exception 'Loan not found'; end if;

  select exists(select 1 from public.payments p where p.loan_id = p_loan_id)
    or exists(select 1 from public.loan_adjustments a where a.loan_id = p_loan_id)
    into v_has_activity;
  v_plan_changed := row(
    v_loan.initial_amount_cents, v_loan.repayment_type, v_loan.installment_amount_cents,
    v_loan.installment_count, v_loan.first_due_date, v_loan.target_due_date
  ) is distinct from row(
    p_initial_amount_cents, p_repayment_type, p_installment_amount_cents,
    p_installment_count, p_first_due_date, p_target_due_date
  );

  if v_has_activity and v_loan.initial_amount_cents <> p_initial_amount_cents then
    raise exception 'The original principal cannot be changed after a payment or forgiveness adjustment.';
  end if;
  if v_plan_changed and v_has_activity then
    if not coalesce(p_agreement_attested, false) then
      raise exception 'Confirm that the revised repayment plan was discussed and agreed with the borrower.';
    end if;
    select coalesce(sum(p.amount_cents), 0) into v_received
    from public.payments p where p.loan_id = p_loan_id;
    select coalesce(sum(a.amount_cents), 0) into v_forgiven
    from public.loan_adjustments a where a.loan_id = p_loan_id;
    if v_loan.initial_amount_cents - v_received - v_forgiven <= 0 then
      raise exception 'A fully settled loan plan cannot be revised.';
    end if;
  end if;

  update public.loans
  set borrower_name = left(btrim(p_borrower_name), 120),
      borrower_contact = left(coalesce(p_borrower_contact, ''), 200),
      start_date = coalesce(p_start_date, current_date),
      target_due_date = p_target_due_date,
      initial_amount_cents = p_initial_amount_cents,
      reason = left(coalesce(p_reason, ''), 500),
      repayment_type = p_repayment_type,
      installment_amount_cents = p_installment_amount_cents,
      installment_count = p_installment_count,
      first_due_date = p_first_due_date,
      last_plan_agreed_by = case when v_plan_changed and v_has_activity and p_agreement_attested then auth.uid() else v_loan.last_plan_agreed_by end,
      last_plan_agreed_at = case when v_plan_changed and v_has_activity and p_agreement_attested then now() else v_loan.last_plan_agreed_at end,
      updated_at = now()
  where id = p_loan_id and owner_id = auth.uid();

  return p_loan_id;
end;
$$;

drop trigger if exists loans_sync_installments on public.loans;
create trigger loans_sync_installments
  after insert or update of initial_amount_cents, repayment_type, installment_amount_cents,
    installment_count, first_due_date, target_due_date
  on public.loans
  for each row execute function public.paymeback_sync_installments();

create or replace function public.paymeback_update_loan_status(p_loan_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_principal bigint;
  v_received bigint;
  v_forgiven bigint;
begin
  select l.initial_amount_cents into v_principal
  from public.loans l where l.id = p_loan_id;
  if not found then return; end if;

  select coalesce(sum(p.amount_cents), 0) into v_received
  from public.payments p where p.loan_id = p_loan_id;
  select coalesce(sum(a.amount_cents), 0) into v_forgiven
  from public.loan_adjustments a where a.loan_id = p_loan_id;

  update public.loans
  set status = case
    when v_principal - v_received - v_forgiven <= 0 then 'paid_in_full'
    when status = 'paid_in_full' then 'active'
    else status
  end,
  updated_at = now()
  where id = p_loan_id;
end;
$$;

create or replace function public.record_loan_payment(
  p_loan_id uuid,
  p_payment_date date,
  p_amount_cents bigint,
  p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_loan public.loans%rowtype;
  v_received bigint;
  v_forgiven bigint;
  v_remaining bigint;
  v_to_allocate bigint;
  v_alloc bigint;
  v_installment record;
  v_payment_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'Payment amount must be positive'; end if;

  select l.* into v_loan
  from public.loans l
  where l.id = p_loan_id and l.owner_id = auth.uid()
  for update;
  if not found then raise exception 'Loan not found'; end if;
  if v_loan.status = 'archived' then raise exception 'Restore this loan before recording a payment'; end if;

  select coalesce(sum(p.amount_cents), 0) into v_received
  from public.payments p where p.loan_id = p_loan_id;
  select coalesce(sum(a.amount_cents), 0) into v_forgiven
  from public.loan_adjustments a where a.loan_id = p_loan_id;
  v_remaining := v_loan.initial_amount_cents - v_received - v_forgiven;
  if p_amount_cents > v_remaining then raise exception 'Payment exceeds the remaining balance'; end if;

  insert into public.payments (loan_id, owner_id, payment_date, amount_cents, note)
  values (p_loan_id, auth.uid(), coalesce(p_payment_date, current_date), p_amount_cents, left(coalesce(p_note, ''), 300))
  returning id into v_payment_id;

  v_to_allocate := p_amount_cents;
  for v_installment in
    select i.id, i.amount_due_cents, i.paid_cents, i.forgiven_cents
    from public.installments i
    where i.loan_id = p_loan_id and i.is_current and i.paid_cents + i.forgiven_cents < i.amount_due_cents
    order by i.due_date nulls last, i.installment_number
    for update
  loop
    exit when v_to_allocate <= 0;
    v_alloc := least(v_to_allocate, v_installment.amount_due_cents - v_installment.paid_cents - v_installment.forgiven_cents);
    update public.installments set paid_cents = paid_cents + v_alloc where id = v_installment.id;
    v_to_allocate := v_to_allocate - v_alloc;
  end loop;

  perform public.paymeback_update_loan_status(p_loan_id);
  return v_payment_id;
end;
$$;

create or replace function public.forgive_loan_balance(
  p_loan_id uuid,
  p_adjustment_date date,
  p_amount_cents bigint,
  p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_loan public.loans%rowtype;
  v_received bigint;
  v_forgiven bigint;
  v_remaining bigint;
  v_to_allocate bigint;
  v_alloc bigint;
  v_installment record;
  v_adjustment_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'Forgiveness amount must be positive'; end if;

  select l.* into v_loan
  from public.loans l
  where l.id = p_loan_id and l.owner_id = auth.uid()
  for update;
  if not found then raise exception 'Loan not found'; end if;

  select coalesce(sum(p.amount_cents), 0) into v_received
  from public.payments p where p.loan_id = p_loan_id;
  select coalesce(sum(a.amount_cents), 0) into v_forgiven
  from public.loan_adjustments a where a.loan_id = p_loan_id;
  v_remaining := v_loan.initial_amount_cents - v_received - v_forgiven;
  if p_amount_cents > v_remaining then raise exception 'Forgiveness exceeds the remaining balance'; end if;

  insert into public.loan_adjustments (loan_id, owner_id, adjustment_date, amount_cents, kind, note)
  values (p_loan_id, auth.uid(), coalesce(p_adjustment_date, current_date), p_amount_cents, 'forgiveness', left(coalesce(p_note, ''), 300))
  returning id into v_adjustment_id;

  v_to_allocate := p_amount_cents;
  for v_installment in
    select i.id, i.amount_due_cents, i.paid_cents, i.forgiven_cents
    from public.installments i
    where i.loan_id = p_loan_id and i.is_current and i.paid_cents + i.forgiven_cents < i.amount_due_cents
    order by i.due_date nulls last, i.installment_number
    for update
  loop
    exit when v_to_allocate <= 0;
    v_alloc := least(v_to_allocate, v_installment.amount_due_cents - v_installment.paid_cents - v_installment.forgiven_cents);
    update public.installments set forgiven_cents = forgiven_cents + v_alloc where id = v_installment.id;
    v_to_allocate := v_to_allocate - v_alloc;
  end loop;

  perform public.paymeback_update_loan_status(p_loan_id);
  return v_adjustment_id;
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
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then
    return null;
  end if;

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
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'date', p.payment_date, 'amountCents', p.amount_cents, 'note', p.note
      ) order by p.payment_date desc, p.created_at desc)
      from public.payments p where p.loan_id = l.id
    ), '[]'::jsonb),
    'adjustments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'date', a.adjustment_date, 'amountCents', a.amount_cents, 'note', a.note, 'kind', a.kind
      ) order by a.adjustment_date desc, a.created_at desc)
      from public.loan_adjustments a where a.loan_id = l.id
    ), '[]'::jsonb),
    'installments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'number', i.installment_number, 'dueDate', i.due_date,
        'amountCents', i.amount_due_cents, 'paidCents', i.paid_cents,
        'forgivenCents', i.forgiven_cents
      ) order by i.installment_number)
      from public.installments i where i.loan_id = l.id and i.is_current
    ), '[]'::jsonb),
    'paymentOptions', jsonb_build_object(
      'venmo', coalesce(s.venmo, ''),
      'cashapp', coalesce(s.cashapp, ''),
      'zelle', coalesce(s.zelle, '')
    )
  )
  into v_statement
  from public.share_links sl
  join public.loans l on l.id = sl.loan_id
  left join public.user_settings s on s.user_id = l.owner_id
  where sl.token_hash = pg_catalog.encode(
      pg_catalog.sha256(pg_catalog.convert_to(p_token, 'UTF8')),
      'hex'
    )
    and sl.revoked_at is null
    and (sl.expires_at is null or sl.expires_at > now());

  return v_statement;
end;
$$;

create or replace function public.import_legacy_loan(
  p_source_id text,
  p_payload jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_loan_id uuid;
  v_payment jsonb;
  v_amount bigint;
  v_payment_sum bigint := 0;
  v_principal bigint;
  v_status text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_source_id is null or length(p_source_id) = 0 or length(p_source_id) > 200 then
    raise exception 'Invalid legacy loan identifier';
  end if;
  if jsonb_typeof(p_payload) <> 'object' then raise exception 'Invalid loan data'; end if;
  v_principal := (p_payload->>'initial_amount_cents')::bigint;
  if v_principal is null or v_principal <= 0 then raise exception 'Invalid loan principal'; end if;

  insert into public.loans (
    owner_id, legacy_id, borrower_name, borrower_contact, start_date, target_due_date,
    initial_amount_cents, reason, repayment_type, status
  ) values (
    auth.uid(), p_source_id,
    left(btrim(p_payload->>'borrower_name'), 120),
    left(coalesce(p_payload->>'borrower_contact', ''), 200),
    coalesce((p_payload->>'start_date')::date, current_date),
    nullif(p_payload->>'target_due_date', '')::date,
    v_principal,
    left(coalesce(p_payload->>'reason', ''), 500),
    'flexible',
    'active'
  )
  on conflict (owner_id, legacy_id) where legacy_id is not null do nothing
  returning id into v_loan_id;

  if v_loan_id is null then
    select l.id into v_loan_id
    from public.loans l
    where l.owner_id = auth.uid() and l.legacy_id = p_source_id;
    return v_loan_id;
  end if;

  if jsonb_typeof(coalesce(p_payload->'payments', '[]'::jsonb)) <> 'array' then
    raise exception 'Invalid payment history';
  end if;

  for v_payment in select value from jsonb_array_elements(coalesce(p_payload->'payments', '[]'::jsonb))
  loop
    v_amount := round((v_payment->>'amount')::numeric * 100)::bigint;
    if v_amount is null or v_amount <= 0 then raise exception 'Invalid legacy payment amount'; end if;
    v_payment_sum := v_payment_sum + v_amount;
    if v_payment_sum > v_principal then raise exception 'Legacy payments exceed the loan principal'; end if;
    perform public.record_loan_payment(
      v_loan_id,
      coalesce(nullif(v_payment->>'date', '')::date, current_date),
      v_amount,
      left(coalesce(v_payment->>'note', ''), 300)
    );
  end loop;

  v_status := case
    when p_payload->>'status' = 'archived' then 'archived'
    when v_payment_sum >= v_principal then 'paid_in_full'
    else 'active'
  end;
  update public.loans set status = v_status where id = v_loan_id;
  return v_loan_id;
end;
$$;

revoke all on function public.paymeback_sync_installments() from public, anon, authenticated;
revoke all on function public.paymeback_update_loan_status(uuid) from public, anon, authenticated;
revoke all on function public.save_loan(uuid, text, text, date, date, bigint, text, text, bigint, integer, date, boolean) from public, anon;
revoke all on function public.record_loan_payment(uuid, date, bigint, text) from public, anon;
revoke all on function public.forgive_loan_balance(uuid, date, bigint, text) from public, anon;
revoke all on function public.get_shared_statement(text) from public;
revoke all on function public.import_legacy_loan(text, jsonb) from public, anon;
grant execute on function public.record_loan_payment(uuid, date, bigint, text) to authenticated;
grant execute on function public.forgive_loan_balance(uuid, date, bigint, text) to authenticated;
grant execute on function public.save_loan(uuid, text, text, date, date, bigint, text, text, bigint, integer, date, boolean) to authenticated;
grant execute on function public.get_shared_statement(text) to anon, authenticated;
grant execute on function public.import_legacy_loan(text, jsonb) to authenticated;
