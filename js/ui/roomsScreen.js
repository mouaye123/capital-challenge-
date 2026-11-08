/* =====================================================================
   Écrans « Jouer » : créer ou rejoindre une salle.
   ===================================================================== */
import { supabase } from '../supabaseClient.js';
import { getUser } from '../auth.js';
import {
  createRoom, joinRoom, findActiveRoom, leaveRoom
} from '../rooms.js';
import { getGameConfig } from '../gameConfig.js';
import { navigate } from '../router.js';
import { escapeHtml, formatCredits, friendlyError, toast } from '../utils.js';

const TARGETS = [15, 20, 25, 30, 35, 40, 45, 50, 55];

export async function renderPlay(root) {
  const user = await getUser();
  if (!user) { navigate('/connexion'); return; }

  const [activeRoom, walletRes, config] = await Promise.all([
    findActiveRoom(user.id).catch(() => null),
    supabase.from('wallets').select('balance').eq('user_id', user.id).maybeSingle(),
    getGameConfig()
  ]);
  const balance = walletRes.data?.balance ?? 0;
  const entryFee = Number(config.entry_fee) || 0;
  const canAfford = balance >= entryFee;

  root.innerHTML = `
    <div class="page-head">
      <div>
        <h1>Jouer</h1>
        <p>Créez une salle privée ou entrez le code d’une salle existante.</p>
      </div>
      <div class="badge badge--gold">Solde : ${formatCredits(balance)} crédits</div>
    </div>

    ${activeRoom ? `
      <div class="alert alert--gold" style="margin-bottom:20px">
        <div class="row row--between">
          <span><strong>Vous êtes déjà dans une salle</strong> (${escapeHtml(activeRoom.code)}).</span>
          <div class="row">
            <a class="btn btn--sm btn--teal" href="#/partie/${activeRoom.id}">Reprendre</a>
            <button class="btn btn--sm btn--danger" id="leave-active">Quitter</button>
          </div>
        </div>
      </div>` : ''}

    <div class="choice-grid">
      <section class="card card--gold">
        <div class="card__title"><h2>Créer une salle</h2><span class="badge badge--gold">Hôte</span></div>
        <p class="muted">Choisissez le nombre cible de pays. Il sera ajusté au lancement pour que chaque joueur propose le même nombre de fois.</p>

        <form id="create-form" class="stack">
          <fieldset style="border:0;padding:0;margin:0">
            <legend class="small muted" style="margin-bottom:8px">Nombre cible de pays</legend>
            <div class="radio-grid">
              ${TARGETS.map((t) => `
                <input type="radio" name="target" id="target-${t}" value="${t}" ${t === 20 ? 'checked' : ''}>
                <label for="target-${t}">${t}</label>`).join('')}
            </div>
          </fieldset>

          <div class="alert alert--info">
            Frais d’entrée : <strong>${formatCredits(entryFee)} crédits</strong> par joueur, débités une seule fois au lancement.
            La salle d’attente expire au bout de ${config.lobby_minutes} minutes.
          </div>

          <button class="btn btn--gold btn--lg" type="submit" id="create-btn" ${canAfford ? '' : 'disabled'}>
            ${canAfford ? 'Créer la salle' : `Solde insuffisant (${formatCredits(entryFee)} requis)`}
          </button>
          ${canAfford ? '' : `<a class="small center" href="#/portefeuille">Recharger mon portefeuille</a>`}
        </form>
      </section>

      <section class="card">
        <div class="card__title"><h2>Rejoindre une salle</h2><span class="badge">Code à 6 caractères</span></div>
        <p class="muted">Demandez le code à l’hôte, ou ouvrez directement son lien d’invitation.</p>

        <form id="join-form" class="stack">
          <div class="field">
            <label for="code">Code de la salle</label>
            <input class="input input--code" id="code" name="code" maxlength="6"
                   autocomplete="off" autocapitalize="characters" spellcheck="false"
                   placeholder="ABC234" required>
          </div>
          <button class="btn btn--teal btn--lg" type="submit" id="join-btn">Rejoindre</button>
        </form>

        <div class="divider"></div>
        <p class="small muted mt-0">
          L’hôte peut lancer dès que ${config.min_players} joueurs sont présents et que tous sont prêts.
          Il est impossible de rejoindre une partie déjà lancée.
        </p>
      </section>
    </div>
  `;

  root.querySelector('#leave-active')?.addEventListener('click', async (event) => {
    if (activeRoom.phase !== 'waiting') {
      const confirmed = window.confirm(
        'Cette partie est en cours : la quitter vous met en forfait (aucun remboursement). Continuer ?'
      );
      if (!confirmed) return;
    }
    const button = event.currentTarget;
    button.disabled = true;
    try {
      await leaveRoom(activeRoom.id);
      toast('Salle quittée.', 'success');
      renderPlay(root);
    } catch (error) {
      toast(friendlyError(error), 'error');
      button.disabled = false;
    }
  });

  root.querySelector('#create-form')?.addEventListener('submit', async (event) => {
    event.preventDefault();
    const button = root.querySelector('#create-btn');
    const target = Number(new FormData(event.currentTarget).get('target'));
    button.disabled = true;
    button.textContent = 'Création…';
    try {
      const result = await createRoom(target);
      if (!result?.ok) throw new Error(result?.reason || 'Création impossible');
      toast(`Salle ${result.code} créée. Invitez vos amis !`, 'success');
      navigate(`/partie/${result.id}`);
    } catch (error) {
      toast(friendlyError(error), 'error');
      button.disabled = false;
      button.textContent = 'Créer la salle';
    }
  });

  root.querySelector('#join-form')?.addEventListener('submit', async (event) => {
    event.preventDefault();
    const button = root.querySelector('#join-btn');
    const input = root.querySelector('#code');
    const code = input.value.trim().toUpperCase();

    if (code.length !== 6) {
      toast('Le code doit contenir 6 caractères.', 'error');
      input.focus();
      return;
    }

    button.disabled = true;
    button.textContent = 'Connexion…';
    try {
      const result = await joinRoom(code);
      if (result?.ok) {
        toast(`Bienvenue dans la salle ${result.code}.`, 'success');
        navigate(`/partie/${result.id}`);
        return;
      }

      const messages = {
        not_found: 'Aucune salle ne porte ce code.',
        started: 'Cette partie a déjà commencé.',
        expired: 'Cette salle a expiré.',
        full: `Cette salle est complète (${config.max_players} joueurs maximum).`,
        already_in_room: 'Vous êtes déjà dans une autre salle en cours.'
      };
      if (result?.reason === 'already_in_room') {
        const room = await findActiveRoom(user.id);
        if (room) {
          toast('Reprise de votre salle en cours.', 'info');
          navigate(`/partie/${room.id}`);
          return;
        }
      }
      toast(messages[result?.reason] || 'Impossible de rejoindre cette salle.', 'error');
      button.disabled = false;
      button.textContent = 'Rejoindre';
    } catch (error) {
      toast(friendlyError(error), 'error');
      button.disabled = false;
      button.textContent = 'Rejoindre';
    }
  });
}
