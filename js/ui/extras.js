/* =====================================================================
   Missions, historique, achats et règles.
   ===================================================================== */
import { supabase } from '../supabaseClient.js';
import { getUser } from '../auth.js';
import { getDailyMissions } from '../missions.js';
import { fetchHistory } from '../history.js';
import { fetchWallet } from '../wallet.js';
import { getGameConfig, DEFAULT_CONFIG } from '../gameConfig.js';
import { PURCHASES_ENABLED } from '../config.js';
import { navigate } from '../router.js';
import {
  escapeHtml, formatCredits, formatDate, formatShortDate, friendlyError,
  toast, difficultyLabel
} from '../utils.js';

/* =====================================================================
   Missions du jour
   ===================================================================== */
export async function renderMissions(root) {
  const user = await getUser();
  if (!user) { navigate('/connexion'); return; }

  root.innerHTML = `<div class="loading-block"><div class="spinner" role="status"></div>Chargement des missions…</div>`;

  let missions = [];
  let missionsError = null;
  let config = DEFAULT_CONFIG;

  config = await getGameConfig();
  try {
    missions = await getDailyMissions();
  } catch (error) {
    missionsError = error;
    console.error('Missions indisponibles :', error?.message || error);
  }

  if (!missionsError && missions.length === 0) {
    console.warn('Aucune mission générée : vérifier que 05_missions.sql est exécuté et que mission_templates contient ses 12 modèles.');
  }

  const totalEarned = missions.filter((m) => m.completed).reduce((sum, m) => sum + m.reward, 0);
  const totalPossible = missions.reduce((sum, m) => sum + m.reward, 0);

  root.innerHTML = `
    <div class="page-head">
      <div>
        <h1>Missions du jour</h1>
        <p>Trois missions, renouvelées chaque jour à minuit UTC (heure d’Abidjan).</p>
      </div>
      <div class="badge badge--gold">${formatCredits(totalEarned)} / ${formatCredits(totalPossible)} crédits gagnés</div>
    </div>

    ${missionsError ? `
      <div class="alert alert--error">
        <strong>Impossible de charger les missions.</strong><br>
        ${escapeHtml(friendlyError(missionsError))}
        <details class="mt-2 small">
          <summary>Détail technique</summary>
          <pre style="white-space:pre-wrap;margin:8px 0 0">${escapeHtml(missionsError?.message || String(missionsError))}</pre>
        </details>
        <div class="row mt-4">
          <button class="btn btn--ghost btn--sm" id="retry-missions" type="button">Réessayer</button>
          <a class="btn btn--ghost btn--sm" href="#/tableau-de-bord">Tableau de bord</a>
        </div>
      </div>` : missions.length === 0 ? `
      <div class="empty">
        <div class="empty__icon">✦</div>
        <h2>Aucune mission pour aujourd’hui</h2>
        <p>Les missions sont créées automatiquement à votre première visite du jour.
           Si ce message persiste, le catalogue de missions n’est probablement pas installé côté serveur.</p>
        <div class="row" style="justify-content:center">
          <button class="btn btn--ghost" id="retry-missions" type="button">Réessayer</button>
          <a class="btn btn--ghost" href="#/jouer">Aller jouer</a>
        </div>
      </div>` : `
      <div class="grid grid--3">
        ${missions.map((mission) => {
          const pct = Math.min(100, Math.round((mission.progress / mission.target) * 100));
          return `
            <article class="mission-card ${mission.completed ? 'mission-card--done' : ''}">
              <div class="mission-card__head">
                <div>
                  <div class="mission-card__title">${escapeHtml(mission.title)}</div>
                  <div class="mission-card__desc">${escapeHtml(mission.description)}</div>
                </div>
                <span class="badge ${mission.completed ? 'badge--green' : 'badge--gold'}">${difficultyLabel(mission.difficulty)}</span>
              </div>
              <div class="progress" aria-hidden="true"><span style="width:${pct}%"></span></div>
              <div class="mission-card__foot">
                <span>${mission.progress} / ${mission.target}</span>
                <span class="reward-chip">${mission.completed ? '✔ Récompense versée · ' : ''}+${mission.reward} crédits</span>
              </div>
            </article>`;
        }).join('')}
      </div>`}

    <section class="card card--flat mt-6">
      <div class="card__title"><h2>Comment ça marche ?</h2></div>
      <ul class="small muted" style="padding-left:18px;margin:0">
        <li>Une mission facile, une moyenne et une difficile/très difficile sont tirées chaque jour.</li>
        <li>La progression est calculée à la fin des parties terminées normalement.</li>
        <li>Une partie terminée par forfait ne fait progresser aucune mission (anti-abus).</li>
        <li>Chaque récompense n’est versée qu’une seule fois.</li>
        <li>Le bonus quotidien de ${formatCredits(config.daily_bonus)} crédits est séparé des missions.</li>
      </ul>
      <a class="btn btn--ghost mt-4" href="#/jouer">Jouer pour progresser</a>
    </section>`;

  root.querySelector('#retry-missions')?.addEventListener('click', () => renderMissions(root));
}

/* =====================================================================
   Historique
   ===================================================================== */
export async function renderHistory(root) {
  const user = await getUser();
  if (!user) { navigate('/connexion'); return; }

  root.innerHTML = `<div class="loading-block"><div class="spinner" role="status"></div>Chargement de l’historique…</div>`;

  let games;
  try {
    games = await fetchHistory(user.id, 60);
  } catch (error) {
    root.innerHTML = `<div class="alert alert--error">${escapeHtml(friendlyError(error))}</div>`;
    return;
  }

  root.innerHTML = `
    <div class="page-head">
      <div>
        <h1>Historique des parties</h1>
        <p>Vos participations terminées, vos rangs et vos gains.</p>
      </div>
      <a class="btn btn--gold" href="#/jouer">Rejouer</a>
    </div>

    ${games.length === 0 ? `
      <div class="empty">
        <div class="empty__icon">◷</div>
        <p>Aucune partie terminée pour l’instant.</p>
        <a class="btn btn--gold" href="#/jouer">Créer ma première salle</a>
      </div>` : `
      <div class="card">
        <div class="table-wrap">
          <table class="table">
            <thead>
              <tr>
                <th>Date</th><th>Salle</th><th class="num">Rang</th>
                <th class="num">Score</th><th class="num">Crédits</th><th>Statut</th>
              </tr>
            </thead>
            <tbody>
              ${games.map((g) => `
                <tr>
                  <td class="nowrap">${formatShortDate(g.date)}</td>
                  <td class="mono">${escapeHtml(g.code)}</td>
                  <td class="num">${g.rank ? `#${g.rank}` : '—'}</td>
                  <td class="num">${Number(g.score).toLocaleString('fr-FR', { maximumFractionDigits: 1 })}</td>
                  <td class="num" style="color:${Number(g.reward) > 0 ? 'var(--gold)' : 'var(--muted)'}">
                    ${Number(g.reward) > 0 ? `+${formatCredits(g.reward)}` : '0'}
                  </td>
                  <td>
                    ${g.endedByForfeit
                      ? '<span class="badge badge--red">Forfait</span>'
                      : '<span class="badge badge--green">Terminée</span>'}
                  </td>
                </tr>`).join('')}
            </tbody>
          </table>
        </div>
      </div>`}

    <p class="small muted mt-4">
      Une partie terminée par forfait reste visible, mais ne compte ni pour les missions,
      ni pour les paliers, ni pour les statistiques.
    </p>`;
}

/* =====================================================================
   Achat de crédits
   ===================================================================== */
export async function renderPurchase(root) {
  const user = await getUser();
  if (!user) { navigate('/connexion'); return; }

  if (!PURCHASES_ENABLED) {
    root.innerHTML = `
      <div class="page-head">
        <div>
          <h1>Boutique fermée</h1>
          <p>Les achats de crédits sont temporairement désactivés.</p>
        </div>
        <a class="btn btn--ghost" href="#/portefeuille">Mon portefeuille</a>
      </div>

      <div class="empty">
        <div class="empty__icon">🔒</div>
        <h2>Aucun achat possible pour le moment</h2>
        <p>La recharge de crédits est suspendue pour garantir un classement équitable.
           Aucun débit ne peut être effectué depuis cette page.</p>
        <p class="small muted">Vous pouvez toujours gagner des crédits avec le bonus quotidien,
           les missions et les récompenses de partie.</p>
        <div class="row" style="justify-content:center">
          <a class="btn btn--gold" href="#/portefeuille">Voir mon solde</a>
          <a class="btn btn--ghost" href="#/missions">Faire mes missions</a>
        </div>
      </div>`;
    return;
  }

  root.innerHTML = `<div class="loading-block"><div class="spinner" role="status"></div>Chargement de la boutique…</div>`;

  let packs, purchases, wallet, config;
  try {
    const [packsRes, purchasesRes, walletData, configData] = await Promise.all([
      supabase.from('credit_packs').select('*').order('price_fcfa', { ascending: true }),
      supabase.from('purchases').select('*').eq('user_id', user.id).order('created_at', { ascending: false }).limit(20),
      fetchWallet(user.id),
      getGameConfig()
    ]);
    if (packsRes.error) throw packsRes.error;
    if (purchasesRes.error) throw purchasesRes.error;
    packs = packsRes.data || [];
    purchases = purchasesRes.data || [];
    wallet = walletData;
    config = configData;
  } catch (error) {
    root.innerHTML = `<div class="alert alert--error">${escapeHtml(friendlyError(error))}</div>`;
    return;
  }

  root.innerHTML = `
    <div class="page-head">
      <div>
        <h1>Acheter des crédits</h1>
        <p>Rechargez votre portefeuille pour continuer à jouer.</p>
      </div>
      <div class="badge badge--gold">Solde : ${formatCredits(wallet.balance)} crédits</div>
    </div>

    <div class="alert alert--info" style="margin-bottom:20px">
      <strong>Paiement :</strong> ${Number(config.payments_test_mode) === 1
        ? 'la v1 fonctionne en mode test (crédit immédiat) tant que le branchement Mobile Money n’est pas activé.'
        : 'le paiement est vérifié côté serveur ; un achat ne sera crédité qu’à la confirmation du fournisseur.'}
      Les crédits sont virtuels, non retirables et non convertibles.
    </div>

    <div class="grid grid--3">
      ${packs.map((pack) => `
        <article class="card">
          <div class="card__title">
            <h3>${escapeHtml(pack.label)}</h3>
            <span class="badge badge--gold">${formatCredits(pack.credits)}</span>
          </div>
          <div class="stat-card__value" style="font-size:2rem">${formatCredits(pack.price_fcfa)} <span class="unit">FCFA</span></div>
          <button class="btn btn--gold btn--block mt-4 buy-btn" data-pack="${pack.id}" type="button">
            Acheter
          </button>
        </article>`).join('')}
    </div>

    <section class="card mt-6">
      <div class="card__title"><h2>Mes achats</h2><span class="badge">${purchases.length}</span></div>
      ${purchases.length === 0 ? `<p class="muted">Aucun achat pour l’instant.</p>` : `
        <div class="table-wrap">
          <table class="table">
            <thead><tr><th>Date</th><th class="num">Crédits</th><th class="num">Montant</th><th>Statut</th></tr></thead>
            <tbody>
              ${purchases.map((p) => `
                <tr>
                  <td class="nowrap">${formatDate(p.created_at)}</td>
                  <td class="num">${formatCredits(p.credits)}</td>
                  <td class="num">${formatCredits(p.amount_fcfa)} FCFA</td>
                  <td>
                    ${p.status === 'paid'
                      ? '<span class="badge badge--green">Payé</span>'
                      : p.status === 'pending'
                        ? '<span class="badge badge--gold">En attente</span>'
                        : `<span class="badge badge--red">${escapeHtml(p.status)}</span>`}
                  </td>
                </tr>`).join('')}
            </tbody>
          </table>
        </div>`}
    </section>

    <p class="small muted mt-4">
      Grille indicative à valider avant commercialisation. Les montants sont définis côté serveur
      (table <span class="mono">credit_packs</span>) et peuvent être ajustés par l’administrateur.
    </p>`;

  root.querySelectorAll('.buy-btn').forEach((button) => {
    button.addEventListener('click', async () => {
      const packId = Number(button.dataset.pack);
      button.disabled = true;
      button.textContent = 'Traitement…';
      try {
        const { data, error } = await supabase.rpc('create_purchase', { p_pack: packId });
        if (error) throw error;
        if (data?.status === 'paid') {
          toast(`Achat crédité : +${formatCredits(data.credits)} crédits.`, 'success');
          renderPurchase(root);
        } else {
          toast('Achat créé. Il sera crédité après confirmation du paiement.', 'info');
          renderPurchase(root);
        }
      } catch (error) {
        toast(friendlyError(error), 'error');
        button.disabled = false;
        button.textContent = 'Acheter';
      }
    });
  });
}

/* =====================================================================
   Règles du jeu
   ===================================================================== */
export async function renderRules(root) {
  const config = await getGameConfig();

  root.innerHTML = `
    <div class="page-head">
      <div>
        <h1>Règles du jeu</h1>
        <p>Tout ce qu’il faut savoir avant de lancer une salle.</p>
      </div>
      <a class="btn btn--gold" href="#/jouer">Jouer</a>
    </div>

    <div class="container-mid stack">
      <section class="card">
        <h2 class="mt-0">1. La salle</h2>
        <p>De ${config.min_players} à ${config.max_players} joueurs. Le créateur choisit une cible de 15 à 55 pays ; le serveur ajuste
        le total au multiple du nombre de joueurs le plus proche pour que chacun propose autant de fois.
        Une salle d’attente expire après ${config.lobby_minutes} minutes. On ne peut pas rejoindre après le lancement.</p>
        <p>Les frais d’entrée de <strong>${formatCredits(config.entry_fee)} crédits</strong> sont débités une seule fois, au lancement,
        pour tous les joueurs. Si un débit échoue, toute l’opération est annulée.</p>
      </section>

      <section class="card">
        <h2 class="mt-0">2. Le tour</h2>
        <p>Le joueur dont c’est le tour choisit librement un pays non encore joué et saisit
        sa capitale en secret (${config.pick_seconds} secondes). Les autres joueurs ont ensuite ${config.answer_seconds} secondes pour
        répondre. Dès que tous les joueurs présents ont validé, la révélation peut arriver plus tôt.</p>
        <p>Une réponse validée est <strong>verrouillée</strong>. Si le proposant ne joue pas,
        un pays est tiré au hasard et il marque 0 pour ce tour.</p>
      </section>

      <section class="card">
        <h2 class="mt-0">3. Correction et joker</h2>
        <ul class="small" style="padding-left:18px">
          <li>Les accents, majuscules, espaces, tirets et apostrophes sont ignorés.</li>
          <li>Une petite faute est tolérée : 1 lettre pour un nom de 5 à 8 lettres, 2 à partir de 9 lettres,
              aucune sous 5 lettres, et la première lettre doit être la même.</li>
          <li>Une saisie plus proche de la capitale d’un autre pays est refusée
              (Kingston ≠ Kingstown, Rome ≠ Lomé).</li>
          <li>Première petite faute acceptée : 0,5 point et le <strong>joker</strong> est consommé.
              Les suivantes valent 0. Une réponse parfaite vaut toujours 1 point.</li>
        </ul>
      </section>

      <section class="card">
        <h2 class="mt-0">4. Points et récompenses</h2>
        <p>Chaque bonne réponse rapporte 1 point (0,5 avec joker). Si personne ne trouve,
        la réponse secrète du proposant est notée. Le classement final départage les égalités
        du podium par des blocs d’au moins ${config.tiebreak_min_block} pays (multiples du nombre de joueurs actifs),
        puis par le nombre de réponses parfaites et le temps de réponse.</p>
        <p>Récompenses : <strong>${formatCredits(config.reward_1)}</strong> crédits pour le 1er,
        <strong>${formatCredits(config.reward_2)}</strong> pour le 2e,
        <strong>${formatCredits(config.reward_3)}</strong> pour le 3e. Dans une salle de 2 joueurs,
        seules les deux premières sont attribuées.</p>
      </section>

      <section class="card">
        <h2 class="mt-0">5. Absence et forfait</h2>
        <p>Un joueur est considéré absent après ${config.reconnect_seconds} secondes sans signal.
        ${config.forfeit_missed_turns} tours manqués, ou le fait de quitter la partie, entraînent un forfait : le joueur reste visible au classement
        mais est exclu du podium et des récompenses. Ses frais ne sont pas remboursés.
        S’il ne reste qu’un joueur actif, la partie s’arrête et il reçoit la récompense du 1er.
        Une partie terminée ainsi ne compte pas pour les missions ni les statistiques.</p>
      </section>

      <section class="card card--flat">
        <h2 class="mt-0">6. Crédits virtuels</h2>
        <p class="small muted">Les crédits de Capital Challenge sont une monnaie virtuelle.
        Ils ne peuvent être ni retirés, ni convertis en argent réel, ni transférés.
        Le bonus quotidien de ${formatCredits(config.daily_bonus)} crédits et les missions permettent de rejouer gratuitement.</p>
      </section>
    </div>`;
}
