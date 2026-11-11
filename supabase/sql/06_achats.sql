-- =====================================================================
-- CAPITAL CHALLENGE — 06_achats.sql
-- Boutique de crédits (packs, achats, fonction serveur).
--
-- IMPORTANT : la boutique est FERMÉE par défaut. `payments_test_mode`
-- vaut 0 (voir 01_schema.sql) et 07_correctif.sql révoque l'exécution de
-- `create_purchase`. Aucun crédit ne peut donc être ajouté depuis le
-- navigateur. Pour rouvrir : voir la note en fin de 07_correctif.sql.
--
-- Ré-exécutable et tolérant à un schéma plus ancien.
-- =====================================================================

-- Une ancienne définition au type de retour différent empêcherait
-- `create or replace` : on supprime d'abord (aucune donnée touchée).
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'create_purchase'
  loop
    begin
      execute format('drop function %s cascade', f.sig);
    exception when others then
      raise notice 'Fonction % non supprimée : %', f.sig, sqlerrm;
    end;
  end loop;
end;
$$;

create table if not exists credit_packs (
  id         smallint primary key,
  label      text,
  credits    int,
  price_fcfa int,
  active     boolean default true
);

alter table credit_packs add column if not exists label text;
alter table credit_packs add column if not exists credits int;
alter table credit_packs add column if not exists price_fcfa int;
alter table credit_packs add column if not exists active boolean default true;

create table if not exists purchases (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references profiles(id) on delete cascade,
  pack_id      smallint,
  credits      int,
  amount_fcfa  int,
  status       text default 'pending',
  provider     text,
  provider_ref text,
  created_at   timestamptz default now(),
  paid_at      timestamptz
);

alter table purchases add column if not exists pack_id smallint;
alter table purchases add column if not exists credits int;
alter table purchases add column if not exists amount_fcfa int;
alter table purchases add column if not exists status text;
alter table purchases add column if not exists provider text;
alter table purchases add column if not exists provider_ref text;
alter table purchases add column if not exists created_at timestamptz default now();
alter table purchases add column if not exists paid_at timestamptz;

do $$
begin
  insert into credit_packs (id, label, credits, price_fcfa)
  select v.id, v.label, v.credits, v.price_fcfa
  from (values
    (1::smallint, 'Pack découverte',   500,   500),
    (2::smallint, 'Pack joueur',      1200,  1000),
    (3::smallint, 'Pack compétiteur', 3000,  2000),
    (4::smallint, 'Pack champion',    7000,  4000)
  ) as v(id, label, credits, price_fcfa)
  where not exists (select 1 from credit_packs p where p.id = v.id);
exception when others then
  raise notice 'Packs non initialisés : %', sqlerrm;
end;
$$;

do $$
begin
  begin
    create index if not exists purchases_user_idx
      on purchases (user_id, created_at desc);
  exception when others then
    raise notice 'Index achats non créé : %', sqlerrm;
  end;

  begin
    alter table credit_packs enable row level security;
    alter table purchases    enable row level security;

    drop policy if exists credit_packs_select on credit_packs;
    create policy credit_packs_select on credit_packs
      for select to authenticated using (true);

    drop policy if exists purchases_select on purchases;
    create policy purchases_select on purchases
      for select to authenticated using (user_id = auth.uid());

    revoke all on table credit_packs, purchases from anon, authenticated;
    grant select on table credit_packs, purchases to authenticated;
  exception when others then
    raise notice 'Sécurité de la boutique non appliquée : %', sqlerrm;
  end;
end;
$$;

-- ---------------------------------------------------------------------
-- Création d'un achat.
--   payments_test_mode = 1 : crédit immédiat (développement uniquement).
--   payments_test_mode = 0 : achat « en attente », crédité seulement par
--                            un webhook serveur vérifié.
-- ---------------------------------------------------------------------
create or replace function create_purchase(p_pack smallint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_pack  credit_packs%rowtype;
  v_test  boolean;
  v_id    uuid;
  v_bal   int;
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;
  if cc_config_int('payments_test_mode', 0) <> 1 then
    raise exception 'Boutique fermée : les achats de crédits sont désactivés';
  end if;

  select * into v_pack from credit_packs where id = p_pack;
  if v_pack.id is null then raise exception 'Pack inconnu'; end if;

  v_test := true;

  insert into purchases (user_id, pack_id, credits, amount_fcfa,
                         status, provider, paid_at)
  values (v_uid, v_pack.id, v_pack.credits, v_pack.price_fcfa,
          'paid', 'test', now())
  returning id into v_id;

  perform wallet_apply(
    v_uid, v_pack.credits, 'purchase',
    'purchase:' || v_id::text,
    jsonb_build_object('pack_id', v_pack.id, 'amount_fcfa', v_pack.price_fcfa)
  );
  select balance into v_bal from wallets where user_id = v_uid;

  return jsonb_build_object(
    'ok', true, 'status', 'paid', 'purchase_id', v_id,
    'credits', v_pack.credits, 'balance', v_bal
  );
end;
$$;

revoke all on function create_purchase(smallint) from public, anon, authenticated;

notify pgrst, 'reload schema';

select
  (select count(*) from credit_packs) as packs,
  (select count(*) from purchases) as achats,
  cc_config_int('payments_test_mode', 0) as paiement_test;
