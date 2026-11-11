-- =====================================================================
-- CAPITAL CHALLENGE — 06_achats.sql
-- Boutique de crédits (packs, achats, fonction serveur).
--
-- IMPORTANT : la boutique est FERMÉE par défaut. `payments_test_mode`
-- vaut 0 (voir 01_schema.sql) et 07_correctif.sql révoque l'exécution de
-- `create_purchase`. Aucun crédit ne peut donc être ajouté depuis le
-- navigateur. Pour rouvrir : voir la note en fin de 07_correctif.sql.
-- =====================================================================

create table if not exists credit_packs (
  id         smallint primary key,
  label      text not null,
  credits    int not null check (credits > 0),
  price_fcfa int not null check (price_fcfa >= 0),
  active     boolean not null default true
);

insert into credit_packs (id, label, credits, price_fcfa) values
  (1, 'Pack découverte',  500,   500),
  (2, 'Pack joueur',     1200,  1000),
  (3, 'Pack compétiteur',3000,  2000),
  (4, 'Pack champion',   7000,  4000)
on conflict (id) do update set
  label      = excluded.label,
  credits    = excluded.credits,
  price_fcfa = excluded.price_fcfa;

create table if not exists purchases (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  pack_id     smallint references credit_packs(id),
  credits     int not null,
  amount_fcfa int not null,
  status      text not null default 'pending'
                check (status in ('pending','paid','failed','cancelled')),
  provider    text,
  provider_ref text,
  created_at  timestamptz not null default now(),
  paid_at     timestamptz
);

create index if not exists purchases_user_idx
  on purchases (user_id, created_at desc);

alter table credit_packs enable row level security;
alter table purchases    enable row level security;

drop policy if exists credit_packs_select on credit_packs;
create policy credit_packs_select on credit_packs
  for select to authenticated using (active);

drop policy if exists purchases_select on purchases;
create policy purchases_select on purchases
  for select to authenticated using (user_id = auth.uid());

revoke all on table credit_packs, purchases from anon;
grant select on table credit_packs to authenticated;
grant select on table purchases to authenticated;

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

  select * into v_pack from credit_packs where id = p_pack and active;
  if v_pack.id is null then raise exception 'Pack inconnu'; end if;

  v_test := cc_config_int('payments_test_mode', 0) = 1;

  insert into purchases (user_id, pack_id, credits, amount_fcfa,
                         status, provider, paid_at)
  values (v_uid, v_pack.id, v_pack.credits, v_pack.price_fcfa,
          case when v_test then 'paid' else 'pending' end,
          case when v_test then 'test' else null end,
          case when v_test then now() else null end)
  returning id into v_id;

  if v_test then
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
  end if;

  return jsonb_build_object(
    'ok', true, 'status', 'pending', 'purchase_id', v_id,
    'credits', v_pack.credits,
    'message', 'Achat enregistré : il sera crédité après confirmation du paiement.'
  );
end;
$$;

revoke all on function create_purchase(smallint) from public, anon, authenticated;
grant execute on function create_purchase(smallint) to authenticated;

notify pgrst, 'reload schema';

select
  (select count(*) from credit_packs) as packs,
  (select count(*) from purchases) as achats,
  cc_config_int('payments_test_mode', 0) as paiement_test;
