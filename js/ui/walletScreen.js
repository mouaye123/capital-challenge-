/* =====================================================================
   Portefeuille de crédits.
   ===================================================================== */
import { getUser } from '../auth.js';
import { fetchWallet, fetchTransactions, claimDailyBonus, transactionLabel } from '../wallet.js';
import { serverNow } from '../rooms.js';
import { getGameConfig } from '../gameConfig.js';
import { navigate } from '../router.js';
import { PURCHASES_ENABLED } from '../config.js';
import { escapeHtml, formatCredits, formatDate, friendlyError, toast } from '../utils.js';

// Date UTC calculée avec l'horloge serveur (repli sur l'horloge locale avant synchro).
function todayUtc() {
  return new Date(serverNow()).toISOString().slice(0, 10);
}

export async function renderWallet(root) {
  const user = await getUser();
  if (!user) { navigate('/connexion'); return; }

  root.innerHTML = `<div class="loading-block"><div class="spinner" role="status"></div>Chargement du portefeuille…</div>`;

  let wallet, transactions, config;
  try {
    [wallet, transactions, config] = await Promise.all([
      fetchWallet(user.id),
      fetchTransactions(user.id, 60),
      getGameConfig()
    ]);
  } catch (error) {
    root.innerHTML = `<div class="alert alert--error">${escapeHtml(friendlyError(error))}</div>`;
    return;
  }

  const canClaim = wallet.last_daily_bonus_on !== todayUtc();

  root.innerHTML = `
    <div class="page-head">
      <div>
        <h1>Portefeuille</h1>
        <p>Vos crédits virtuels, vos gains et vos dépenses.</p>
      </div>
      ${PURCHASES_ENABLED
        ? '<a class="btn btn--gold" href="#/achat">Acheter des crédits</a>'
        : '<span class="badge" title="Achats temporairement désactivés">Boutique fermée</span>'}
    </div>

    ${PURCHASES_ENABLED ? '' : `
      <div class="alert alert--info" style="margin-bottom:20px">
        <strong>Boutique fermée :</strong> les achats de crédits sont désactivés.
        Gagnez des crédits avec le bonus quotidien, les missions et les récompenses de partie.
      </div>`}

    <section class="balance-hero">
      <div>
        <div class="balance-hero__label">Solde disponible</div>
        <div class="balance-hero__value">${formatCredits(wallet.balance)}</div>
        <div class="small muted mt-2">1 partie coûte ${formatCredits(config.entry_fee)} crédits · récompenses :
          ${formatCredits(config.reward_1)} / ${formatCredits(config.reward_2)} / ${formatCredits(config.reward_3)}</div>
      </div>
      <div class="stack-sm" style="min-width:240px">
        <button class="btn ${canClaim ? 'btn--gold' : 'btn--ghost'} btn--block" id="claim-btn" ${canClaim ? '' : 'disabled'}>
          ${canClaim ? `Bonus quotidien · +${formatCredits(config.daily_bonus)}` : 'Bonus déjà récupéré aujourd’hui'}
        </button>
        <a class="btn btn--ghost btn--block" href="#/missions">Gagner des crédits avec les missions</a>
      </div>
    </section>

    <section class="card mt-6">
      <div class="card__title">
        <h2>Historique des transactions</h2>
        <span class="badge">${transactions.length} opération(s)</span>
      </div>
      ${transactions.length === 0 ? `
        <div class="empty"><div class="empty__icon">◈</div>Aucune transaction pour l’instant.</div>` : `
        <div class="table-wrap">
          <table class="table">
            <thead>
              <tr><th>Date</th><th>Opération</th><th class="num">Montant</th></tr>
            </thead>
            <tbody>
              ${transactions.map((t) => `
                <tr>
                  <td class="nowrap">${formatDate(t.created_at)}</td>
                  <td>${escapeHtml(transactionLabel(t.type))}</td>
                  <td class="num" style="color:${t.amount >= 0 ? 'var(--green)' : 'var(--red)'}">
                    ${t.amount >= 0 ? '+' : ''}${formatCredits(t.amount)}
                  </td>
                </tr>`).join('')}
            </tbody>
          </table>
        </div>`}
    </section>

    <p class="small muted mt-4">
      Les crédits sont virtuels, non retirables et non convertibles en argent réel.
      Les frais d’entrée sont débités une seule fois, au lancement de la partie.
    </p>
  `;

  root.querySelector('#claim-btn')?.addEventListener('click', async (event) => {
    const button = event.currentTarget;
    button.disabled = true;
    button.textContent = 'Récupération…';
    try {
      const result = await claimDailyBonus();
      if (result?.ok) {
        toast(`+${result.amount} crédits ! Nouveau solde : ${formatCredits(result.balance)}.`, 'success');
      } else {
        toast('Bonus déjà récupéré aujourd’hui.', 'info');
      }
      renderWallet(root);
    } catch (error) {
      toast(friendlyError(error), 'error');
      button.disabled = false;
      button.textContent = `Bonus quotidien · +${formatCredits(config.daily_bonus)}`;
    }
  });
}
