/* =====================================================================
   Tableau de bord, profil et paramètres du compte.
   ===================================================================== */
import { supabase } from '../supabaseClient.js';
import { getUser, signOut } from '../auth.js';
import { fetchWallet, fetchStats, fetchTransactions, claimDailyBonus, transactionLabel } from '../wallet.js';
import { getDailyMissions } from '../missions.js';
import { fetchHistory } from '../history.js';
import { findActiveRoom, serverNow } from '../rooms.js';
import { getGameConfig } from '../gameConfig.js';
import { navigate } from '../router.js';
import { updateShell } from './shell.js';
import {
  escapeHtml, formatCredits, formatDate, friendlyError, initials, toast,
  difficultyLabel, formatShortDate
} from '../utils.js';

async function loadProfile(userId) {
  const { data, error } = await supabase
    .from('profiles')
    .select('username, created_at')
    .eq('id', userId)
    .maybeSingle();
  if (error) throw error;
  return data;
}

// Date UTC calculée avec l'horloge serveur (repli sur l'horloge locale avant synchro).
function todayUtc() {
  return new Date(serverNow()).toISOString().slice(0, 10);
}

function rate(part, total) {
  if (!total) return '—';
  return `${Math.round((Number(part) / Number(total)) * 100)} %`;
}

/* =====================================================================
   Tableau de bord
   ===================================================================== */
export async function renderDashboard(root) {
  const user = await getUser();
  if (!user) { navigate('/connexion'); return; }

  root.innerHTML = `<div class="loading-block"><div class="spinner" role="status"></div>Chargement de votre espace…</div>`;

  let profile, wallet, stats, missions, activeRoom, recent, config;
  try {
    [profile, wallet, stats, missions, activeRoom, recent, config] = await Promise.all([
      loadProfile(user.id),
      fetchWallet(user.id),
      fetchStats(user.id),
      getDailyMissions().catch((error) => {
        console.error('Missions indisponibles :', error?.message || error);
        return [];
      }),
      findActiveRoom(user.id).catch(() => null),
      fetchHistory(user.id, 4).catch(() => []),
      getGameConfig()
    ]);
  } catch (error) {
    root.innerHTML = `<div class="alert alert--error">${escapeHtml(friendlyError(error))}</div>`;
    return;
  }

  const username = profile?.username || 'Joueur';
  const canClaim = wallet.last_daily_bonus_on !== todayUtc();
  const doneMissions = missions.filter((m) => m.completed).length;

  root.innerHTML = `
    <div class="page-head">
      <div>
        <h1>Bonjour, ${escapeHtml(username)}</h1>
        <p>Prêt à défier vos amis sur les capitales du monde ?</p>
      </div>
      <div class="row">
        <a class="btn btn--gold" href="#/jouer">Créer une salle</a>
        <a class="btn btn--ghost" href="#/jouer">Rejoindre</a>
      </div>
    </div>

    ${activeRoom ? `
      <div class="alert alert--info" style="margin-bottom:20px">
        <div class="row row--between">
          <span><strong>Une partie est en cours</strong> — salle ${escapeHtml(activeRoom.code)}.</span>
          <a class="btn btn--sm btn--teal" href="#/partie/${activeRoom.id}">Reprendre</a>
        </div>
      </div>` : ''}

    <section class="grid grid--4" aria-label="Votre portefeuille et vos statistiques">
      <div class="stat-card stat-card--gold">
        <div class="stat-card__label">Solde</div>
        <div class="stat-card__value">${formatCredits(wallet.balance)} <span class="unit">crédits</span></div>
        <a class="small" href="#/portefeuille">Gérer mon portefeuille →</a>
      </div>
      <div class="stat-card">
        <div class="stat-card__label">Parties jouées</div>
        <div class="stat-card__value">${stats?.games_played ?? 0}</div>
        <div class="small muted">${stats?.games_won ?? 0} victoire(s)</div>
      </div>
      <div class="stat-card">
        <div class="stat-card__label">Capitales trouvées</div>
        <div class="stat-card__value">${stats?.capitals_found ?? 0}</div>
        <div class="small muted">Taux de réussite : ${rate(stats?.capitals_found, stats?.answers_total ?? 0)}</div>
      </div>
      <div class="stat-card stat-card--teal">
        <div class="stat-card__label">Missions du jour</div>
        <div class="stat-card__value">${doneMissions}<span class="unit"> / ${missions.length}</span></div>
        <a class="small" href="#/missions">Voir les missions →</a>
      </div>
    </section>

    <section class="grid grid--2 mt-6">
      <div class="card">
        <div class="card__title">
          <h2>Bonus quotidien</h2>
          <span class="badge ${canClaim ? 'badge--gold' : 'badge--green'}">${canClaim ? 'Disponible' : 'Déjà pris'}</span>
        </div>
        <p class="muted">${formatCredits(config.daily_bonus)} crédits offerts une fois par jour (journée UTC, identique à l’heure d’Abidjan).</p>
        <button class="btn ${canClaim ? 'btn--gold' : 'btn--ghost'}" id="claim-bonus-btn" ${canClaim ? '' : 'disabled'}>
          ${canClaim ? `Récupérer mes ${formatCredits(config.daily_bonus)} crédits` : 'Revenez demain'}
        </button>
      </div>

      <div class="card">
        <div class="card__title">
          <h2>Dernières parties</h2>
          <a class="small" href="#/historique">Tout voir</a>
        </div>
        ${recent.length === 0 ? `<p class="muted">Aucune partie terminée pour le moment. À vous de jouer !</p>` : `
          <div class="stack-sm">
            ${recent.map((game) => `
              <div class="row row--between">
                <div>
                  <strong>${game.rank ? `#${game.rank}` : '—'}</strong>
                  <span class="muted small">· ${escapeHtml(game.code)} · ${formatShortDate(game.date)}</span>
                </div>
                <span class="badge ${Number(game.reward) > 0 ? 'badge--gold' : ''}">
                  ${Number(game.reward) > 0 ? `+${formatCredits(game.reward)}` : '0'} crédits
                </span>
              </div>`).join('')}
          </div>`}
      </div>
    </section>

    <section class="card mt-6">
      <div class="card__title">
        <h2>Missions du jour</h2>
        <a class="small" href="#/missions">Détail</a>
      </div>
      ${missions.length === 0 ? `<p class="muted">Les missions apparaîtront ici.</p>` : `
        <div class="grid grid--3">
          ${missions.map((mission) => `
            <div class="mission-card ${mission.completed ? 'mission-card--done' : ''}">
              <div class="mission-card__head">
                <span class="mission-card__title">${escapeHtml(mission.title)}</span>
                <span class="badge">${difficultyLabel(mission.difficulty)}</span>
              </div>
              <div class="mission-card__desc">${escapeHtml(mission.description)}</div>
              <div class="progress" aria-hidden="true">
                <span style="width:${Math.min(100, Math.round((mission.progress / mission.target) * 100))}%"></span>
              </div>
              <div class="mission-card__foot">
                <span>${mission.progress} / ${mission.target}</span>
                <span class="reward-chip">${mission.completed ? '✔ ' : ''}+${mission.reward} crédits</span>
              </div>
            </div>`).join('')}
        </div>`}
    </section>
  `;

  root.querySelector('#claim-bonus-btn')?.addEventListener('click', async (event) => {
    const button = event.currentTarget;
    button.disabled = true;
    button.textContent = 'Récupération…';
    try {
      const result = await claimDailyBonus();
      if (result?.ok) {
        toast(`+${result.amount} crédits ! Nouveau solde : ${formatCredits(result.balance)}.`, 'success');
        renderDashboard(root);
      } else {
        toast('Bonus déjà récupéré aujourd’hui.', 'info');
        renderDashboard(root);
      }
    } catch (error) {
      toast(friendlyError(error), 'error');
      button.disabled = false;
      button.textContent = `Récupérer mes ${formatCredits(config.daily_bonus)} crédits`;
    }
  });
}

/* =====================================================================
   Profil
   ===================================================================== */
export async function renderProfile(root) {
  const user = await getUser();
  if (!user) { navigate('/connexion'); return; }

  root.innerHTML = `<div class="loading-block"><div class="spinner" role="status"></div>Chargement du profil…</div>`;

  let profile, stats, milestones;
  try {
    [profile, stats] = await Promise.all([loadProfile(user.id), fetchStats(user.id)]);
    const { data } = await supabase
      .from('user_milestones')
      .select('code, achieved_at, milestones(title)')
      .eq('user_id', user.id)
      .order('achieved_at', { ascending: false });
    milestones = data || [];
  } catch (error) {
    root.innerHTML = `<div class="alert alert--error">${escapeHtml(friendlyError(error))}</div>`;
    return;
  }

  const username = profile?.username || 'Joueur';
  const s = stats || {};

  root.innerHTML = `
    <div class="page-head">
      <div class="row">
        <span class="avatar avatar--gold" style="width:56px;height:56px;font-size:1.1rem" aria-hidden="true">${escapeHtml(initials(username))}</span>
        <div>
          <h1>${escapeHtml(username)}</h1>
          <p>${escapeHtml(user.email || '')} · inscrit le ${formatDate(profile?.created_at)}</p>
        </div>
      </div>
      <a class="btn btn--ghost" href="#/parametres">Paramètres du compte</a>
    </div>

    <section class="grid grid--4" aria-label="Statistiques détaillées">
      <div class="stat-card"><div class="stat-card__label">Victoires</div><div class="stat-card__value">${s.games_won ?? 0}</div><div class="small muted">${rate(s.games_won, s.games_played)} des parties</div></div>
      <div class="stat-card"><div class="stat-card__label">Podiums</div><div class="stat-card__value">${s.podiums ?? 0}</div><div class="small muted">Top 3</div></div>
      <div class="stat-card"><div class="stat-card__label">Réponses parfaites</div><div class="stat-card__value">${s.perfect_answers ?? 0}</div><div class="small muted">sans faute</div></div>
      <div class="stat-card"><div class="stat-card__label">Taux de réussite</div><div class="stat-card__value">${rate(s.capitals_found, s.answers_total)}</div><div class="small muted">${s.capitals_found ?? 0} / ${s.answers_total ?? 0} réponses</div></div>
    </section>

    <section class="grid grid--2 mt-6">
      <div class="card">
        <div class="card__title"><h2>Activité</h2></div>
        <div class="stack-sm">
          <div class="row row--between"><span class="muted">Parties jouées</span><strong>${s.games_played ?? 0}</strong></div>
          <div class="row row--between"><span class="muted">Pays proposés</span><strong>${s.proposals ?? 0}</strong></div>
          <div class="row row--between"><span class="muted">Capitales trouvées</span><strong>${s.capitals_found ?? 0}</strong></div>
          <div class="row row--between"><span class="muted">Temps de réponse cumulé</span><strong>${Math.round((s.total_response_ms ?? 0) / 1000)} s</strong></div>
        </div>
      </div>

      <div class="card">
        <div class="card__title"><h2>Paliers atteints</h2></div>
        ${milestones.length === 0 ? `<p class="muted">Aucun palier pour l’instant. Terminez votre première partie !</p>` : `
          <div class="stack-sm">
            ${milestones.map((m) => `
              <div class="row row--between">
                <span>${escapeHtml(m.milestones?.title || m.code)}</span>
                <span class="badge badge--gold">${formatShortDate(m.achieved_at)}</span>
              </div>`).join('')}
          </div>`}
      </div>
    </section>

    <section class="card mt-6">
      <div class="card__title"><h2>Dernières transactions</h2><a class="small" href="#/portefeuille">Portefeuille</a></div>
      <div id="profile-tx" class="small muted">Chargement…</div>
    </section>
  `;

  try {
    const tx = await fetchTransactions(user.id, 5);
    const box = root.querySelector('#profile-tx');
    box.innerHTML = tx.length === 0
      ? `<p class="muted">Aucune transaction.</p>`
      : `<div class="stack-sm">${tx.map((t) => `
          <div class="row row--between">
            <span>${escapeHtml(transactionLabel(t.type))} <span class="tiny muted">${formatDate(t.created_at)}</span></span>
            <strong class="${t.amount >= 0 ? 'reward-chip' : ''}">${t.amount >= 0 ? '+' : ''}${formatCredits(t.amount)}</strong>
          </div>`).join('')}</div>`;
  } catch {
    root.querySelector('#profile-tx').textContent = 'Historique indisponible.';
  }
}

/* =====================================================================
   Paramètres
   ===================================================================== */
export async function renderSettings(root) {
  const user = await getUser();
  if (!user) { navigate('/connexion'); return; }

  const profile = await loadProfile(user.id);
  const username = profile?.username || '';

  root.innerHTML = `
    <div class="page-head">
      <div>
        <h1>Paramètres du compte</h1>
        <p>Pseudo, session et informations légales.</p>
      </div>
    </div>

    <div class="container-mid stack">
      <section class="card">
        <div class="card__title"><h2>Pseudo</h2></div>
        <form id="username-form" class="stack">
          <div class="field">
            <label for="username">Nom affiché</label>
            <input class="input" id="username" name="username" value="${escapeHtml(username)}"
                   minlength="3" maxlength="20" required>
            <span class="field__hint">3 à 20 caractères, unique parmi les joueurs.</span>
          </div>
          <button class="btn btn--gold" type="submit" id="save-username">Enregistrer</button>
        </form>
      </section>

      <section class="card">
        <div class="card__title"><h2>Compte</h2></div>
        <div class="stack-sm">
          <div class="row row--between"><span class="muted">Adresse e-mail</span><strong>${escapeHtml(user.email || '—')}</strong></div>
          <div class="row row--between"><span class="muted">Identifiant</span><span class="mono tiny">${escapeHtml(user.id)}</span></div>
        </div>
        <p class="small muted mt-4">Le changement d’adresse e-mail se fait depuis Supabase Auth (hors périmètre v1).</p>
      </section>

      <section class="card">
        <div class="card__title"><h2>Session</h2></div>
        <p class="muted">La déconnexion ferme votre session sur cet appareil.</p>
        <button class="btn btn--danger" id="logout-btn-settings" type="button">Se déconnecter</button>
      </section>

      <section class="card card--flat">
        <div class="card__title"><h3>Crédits virtuels</h3></div>
        <p class="small muted mt-0">
          Les crédits de Capital Challenge sont une monnaie virtuelle. Ils ne peuvent être
          ni retirés, ni convertis en argent réel, ni transférés. Les achats sont définitifs.
        </p>
      </section>
    </div>
  `;

  root.querySelector('#username-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    const button = root.querySelector('#save-username');
    const value = root.querySelector('#username').value.trim();
    if (value.length < 3 || value.length > 20) {
      toast('Le pseudo doit contenir entre 3 et 20 caractères.', 'error');
      return;
    }
    button.disabled = true;
    button.textContent = 'Enregistrement…';
    try {
      const { error } = await supabase.rpc('update_username', { p_username: value });
      if (error) throw error;
      toast('Pseudo mis à jour.', 'success');
      updateShell(user, value);
      button.disabled = false;
      button.textContent = 'Enregistrer';
    } catch (error) {
      toast(friendlyError(error), 'error');
      button.disabled = false;
      button.textContent = 'Enregistrer';
    }
  });

  root.querySelector('#logout-btn-settings').addEventListener('click', async () => {
    await signOut();
    navigate('/');
  });
}
