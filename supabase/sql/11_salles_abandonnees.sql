select 'Correctif 11 — salles abandonnées' as etape;

-- =====================================================================
-- CAPITAL CHALLENGE — 11_salles_abandonnees.sql
--
-- Problème corrigé :
--   Quand une partie est quittée en cours de manche (ou que le navigateur
--   est fermé), la salle reste bloquée en phase « picking / answering /
--   revealing ». Les joueurs restent inscrits dedans, et create_room()
--   refuse alors toute nouvelle salle (« Vous êtes déjà dans une salle en
--   cours »). Impossible de rejouer, définitivement.
--
-- Ce fichier :
--   • ferme les salles réellement abandonnées (aucune activité depuis
--     10 minutes) ;
--   • rembourse les frais d'entrée des parties interrompues ;
--   • fournit cleanup_my_rooms() pour que le site débloque tout seul.
--
-- Ré-exécutable : les remboursements sont idempotents (même référence),
-- aucune partie terminée n'est touchée, aucun crédit n'est dupliqué.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Fermeture des salles abandonnées (+ remboursement de la mise)
-- ---------------------------------------------------------------------
create or replace function cc_close_stale_rooms(p_minutes int default 10, p_user uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room    rooms%rowtype;
  v_player  record;
  v_closed  int := 0;
  v_refunds int := 0;
begin
  for v_room in
    select r.*
    from rooms r
    where (
            (r.phase = 'waiting'
              and r.expires_at is not null
              and r.expires_at < now())
            or
            (r.phase in ('picking','answering','revealing')
              and coalesce(r.updated_at, r.created_at, now())
                  < now() - make_interval(mins => greatest(1, p_minutes)))
          )
      and (p_user is null or exists (
             select 1 from room_players rp
             where rp.room_id = r.id and rp.user_id = p_user))
    order by r.created_at
    limit 50
    for update skip locked
  loop
    -- Remboursement des frais d'entrée (uniquement si la partie a démarré).
    if v_room.started_at is not null then
      for v_player in
        select user_id from room_players where room_id = v_room.id
      loop
        perform wallet_apply(
          v_player.user_id,
          v_room.entry_fee,
          'refund',
          'refund:' || v_room.id::text || ':' || v_player.user_id::text,
          jsonb_build_object('room_id', v_room.id, 'reason', 'stale_room')
        );
        v_refunds := v_refunds + 1;
      end loop;
    end if;

    update room_players
       set is_forfeit = true,
           is_ready = false
     where room_id = v_room.id;

    update rooms
       set phase = 'cancelled',
           finished_at = coalesce(finished_at, now()),
           updated_at = now()
     where id = v_room.id;

    v_closed := v_closed + 1;
  end loop;

  return jsonb_build_object('ok', true, 'fermees', v_closed, 'remboursements', v_refunds);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Fonction appelée par le site : débloque le joueur connecté
-- ---------------------------------------------------------------------
create or replace function cleanup_my_rooms(p_minutes int default 10)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;
  return cc_close_stale_rooms(greatest(1, coalesce(p_minutes, 10)), v_uid);
end;
$$;

revoke all on function cc_close_stale_rooms(int, uuid) from public, anon, authenticated;
revoke all on function cleanup_my_rooms(int) from public, anon, authenticated;
grant execute on function cleanup_my_rooms(int) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 3. Nettoyage immédiat + résultat
-- ---------------------------------------------------------------------
select cc_close_stale_rooms(10, null) as nettoyage;

select
  (select count(*) from rooms where phase in ('waiting','picking','answering','revealing'))
                                                                    as salles_actives,
  (select count(*) from rooms where phase = 'cancelled')            as salles_annulees,
  (select count(*) from rooms)                                      as salles_total,
  (select count(*) from wallet_transactions where type = 'refund')  as remboursements,
  (select count(*) from wallet_transactions where type = 'entry')   as mises_debitees;
