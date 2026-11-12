select 'Correctif 10 — choix du pays et inscription' as etape;

-- =====================================================================
-- CAPITAL CHALLENGE — 10_pick_inscription.sql
--
-- Corrige les deux blocages signalés :
--   1) impossible de valider le pays + la capitale choisie
--   2) inscription qui exige un e-mail de confirmation jamais reçu
--
-- À exécuter APRÈS 01 → 09. Ré-exécutable sans risque :
--   • aucune partie, aucun profil, aucun crédit n'est supprimé
--   • seuls le chrono de choix, la fonction submit_pick et un déclencheur
--     d'inscription sont (re)créés
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Choix du pays : 30 secondes (valeur confirmée)
--    Le réglage est réécrit explicitement pour annuler tout réglage
--    précédent (par exemple un 60 s essayé entre-temps).
-- ---------------------------------------------------------------------
do $$
declare
  v_type text;
  v_cast text;
begin
  if to_regclass('public.game_config') is null then
    raise notice 'game_config absente : réglage pick_seconds inchangé';
    return;
  end if;

  select data_type into v_type
  from information_schema.columns
  where table_schema = 'public' and table_name = 'game_config' and column_name = 'value';

  if v_type is null then
    raise notice 'colonne game_config.value introuvable : réglage inchangé';
    return;
  end if;

  v_cast := case
    when v_type in ('jsonb','json') then 'to_jsonb($2::numeric)'
    when v_type in ('integer','bigint','smallint','numeric','real','double precision')
      then '$2::numeric'
    else '$2::text'
  end;

  execute format(
    'insert into public.game_config (key, value)
     select $1, %s
     where not exists (select 1 from public.game_config g where g.key = $1)', v_cast)
  using 'pick_seconds', 30;

  execute format(
    'update public.game_config set value = %s where key = $1', v_cast)
  using 'pick_seconds', 30;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. submit_pick : validation tolérante
--    Avant : dès que le chrono était dépassé, toute validation était
--    refusée, même si aucun pays n'avait encore été tiré.
--    Maintenant : la validation est acceptée tant que le serveur n'a pas
--    déjà tiré un pays au hasard. Le choix du joueur passe en priorité.
--    Toutes les erreurs sont renvoyées en JSON (plus d'exception brute),
--    pour que le site puisse afficher la cause exacte.
-- ---------------------------------------------------------------------
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'submit_pick'
  loop
    execute format('drop function %s cascade', f.sig);
  end loop;
end;
$$;

create or replace function submit_pick(p_room uuid, p_country smallint, p_capital text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_room   rooms%rowtype;
  v_round  rounds%rowtype;
  v_secret text := trim(coalesce(p_capital, ''));
  v_cap    text;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;
  if length(v_secret) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_capital');
  end if;
  if length(v_secret) > 60 then
    return jsonb_build_object('ok', false, 'reason', 'capital_too_long');
  end if;

  select * into v_room from rooms where id = p_room for update;
  if v_room.id is null then
    return jsonb_build_object('ok', false, 'reason', 'room_not_found');
  end if;
  -- « answering » est accepté : le pays a pu être tiré au hasard pendant la
  -- saisie, le choix du joueur doit encore pouvoir le remplacer (voir plus bas).
  if v_room.phase not in ('picking', 'answering') then
    return jsonb_build_object('ok', false, 'reason', 'not_picking');
  end if;

  select * into v_round from rounds
  where room_id = p_room and round_no = v_room.current_round
  for update;

  if v_round.id is null then
    return jsonb_build_object('ok', false, 'reason', 'round_not_found');
  end if;
  if v_round.proposer_id <> v_uid then
    return jsonb_build_object('ok', false, 'reason', 'not_your_turn');
  end if;

  -- Refus uniquement si un pays a déjà été choisi à la main (vrai « trop
  -- tard ») ou si le tirage automatique a déjà reçu des réponses.
  if v_round.country_id is not null then
    if not v_round.auto_picked then
      return jsonb_build_object('ok', false, 'reason', 'too_late');
    end if;
    if exists (select 1 from answers where round_id = v_round.id) then
      return jsonb_build_object('ok', false, 'reason', 'too_late');
    end if;
  end if;

  if exists (
    select 1 from rounds
    where room_id = p_room and country_id = p_country and round_no <> v_round.round_no
  ) then
    return jsonb_build_object('ok', false, 'reason', 'country_already_played');
  end if;

  select capital_fr into v_cap from countries where id = p_country;
  if v_cap is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_country');
  end if;
  if length(cc_strip(v_secret)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_capital');
  end if;

  update rounds
     set country_id = p_country,
         correct_names = null,
         reveal_note = null,
         status = 'answering',
         auto_picked = false,
         picked_at = now(),
         answer_ends_at = now() + make_interval(secs => cc_config_int('answer_seconds', 15))
   where id = v_round.id;

  insert into round_secrets (round_id, secret)
  values (v_round.id, v_secret)
  on conflict (round_id) do update set secret = excluded.secret;

  update rooms
     set phase = 'answering',
         phase_ends_at = (select answer_ends_at from rounds where id = v_round.id),
         updated_at = now()
   where id = p_room;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function submit_pick(uuid, smallint, text) from public, anon, authenticated;
grant execute on function submit_pick(uuid, smallint, text) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Inscription : confirmation d'e-mail automatique
--    Le projet est réglé avec « Confirm email » activé, mais les e-mails
--    de confirmation n'arrivent pas. Résultat : le compte est créé mais
--    reste inutilisable (connexion refusée : « Email not confirmed »).
--
--    Ce déclencheur marque l'adresse comme confirmée à la création du
--    compte : l'inscription fonctionne immédiatement, sans e-mail.
--
--    Si tu préfères la méthode officielle, tu peux à la place décocher
--    « Confirm email » dans Supabase → Authentication → Providers → Email.
--    Les deux solutions sont compatibles ; ce déclencheur ne gêne pas.
-- ---------------------------------------------------------------------
create or replace function cc_autoconfirm_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if new.email_confirmed_at is null
       and coalesce(new.email, '') <> '' then
      new.email_confirmed_at := now();
    end if;
  exception when others then
    -- Ne bloque jamais une inscription, quoi qu'il arrive.
    null;
  end;
  return new;
end;
$$;

do $$
begin
  execute 'drop trigger if exists cc_autoconfirm_email on auth.users';
  execute 'create trigger cc_autoconfirm_email
             before insert on auth.users
             for each row execute function cc_autoconfirm_email()';
exception when others then
  raise notice 'Déclencheur de confirmation non installé : %', sqlerrm;
end;
$$;

-- Rattrapage : les comptes déjà créés mais jamais confirmés peuvent
-- désormais se connecter (utile pour les comptes de test).
do $$
begin
  update auth.users
     set email_confirmed_at = now()
   where email_confirmed_at is null
     and coalesce(email, '') <> '';
exception when others then
  raise notice 'Rattrapage des comptes non confirmés impossible : %', sqlerrm;
end;
$$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 4. Résultat du correctif
-- ---------------------------------------------------------------------
select
  (select cc_config_int('pick_seconds', 0))                                        as choix_secondes,
  (select cc_config_int('answer_seconds', 0))                                     as reponse_secondes,
  (select count(*) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'submit_pick')                     as fonctions_submit_pick,
  (select count(*) from pg_trigger where tgname = 'cc_autoconfirm_email')         as confirmation_auto,
  (select count(*) from auth.users
    where email_confirmed_at is null and coalesce(email, '') <> '')               as comptes_non_confirmes,
  (select count(*) from public.profiles)                                          as profils,
  (select count(*) from public.rooms where phase = 'picking')                     as salles_en_choix;
