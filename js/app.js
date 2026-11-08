/* =====================================================================
   Capital Challenge — point d'entrée de l'application.
   ===================================================================== */
import { supabase, isConfigured } from './supabaseClient.js';
import { getUser, onAuthChange } from './auth.js';
import { captureInvite, pendingCode } from './pending.js';
import { resumePendingRoom } from './sessionFlow.js';
import { syncServerClock } from './rooms.js';
import { route, startRouter, navigate } from './router.js';
import { updateShell } from './ui/shell.js';
import { renderHome } from './ui/home.js';
import { renderLogin, renderRegister } from './ui/auth.js';
import { renderDashboard, renderProfile, renderSettings } from './ui/account.js';
import { renderWallet } from './ui/walletScreen.js';
import { renderPlay } from './ui/roomsScreen.js';
import { renderRoom } from './ui/play.js';
import { renderMissions, renderHistory, renderPurchase, renderRules } from './ui/extras.js';
import { escapeHtml } from './utils.js';

const app = document.getElementById('app');

function configWarning() {
  app.innerHTML = `
    <div class="config-warning">
      <h1>Configuration requise</h1>
      <p>L’application est prête, mais elle n’est pas encore reliée à Supabase.</p>
      <ol>
        <li>Ouvrez <code>js/config.js</code>.</li>
        <li>Remplacez <code>SUPABASE_URL</code> par l’URL de votre projet
            (Supabase → Project Settings → API).</li>
        <li>Remplacez <code>SUPABASE_ANON_KEY</code> par la clé publique
            <strong>anon / publishable</strong>.</li>
        <li>Ne mettez jamais la clé <code>service_role</code> dans ce fichier.</li>
        <li>Exécutez les fichiers SQL de <code>supabase/sql/</code> dans l’ordre.</li>
      </ol>
      <p class="small">Consultez <code>docs/DEPLOIEMENT.md</code> pour la procédure complète.</p>
    </div>`;
  updateShell(null);
}

async function loadUsername(user) {
  if (!user) return '';
  try {
    const { data } = await supabase
      .from('profiles')
      .select('username')
      .eq('id', user.id)
      .maybeSingle();
    return data?.username || user.email?.split('@')[0] || 'Joueur';
  } catch {
    return user.email?.split('@')[0] || 'Joueur';
  }
}

function registerRoutes() {
  route('/', renderHome);
  route('/connexion', renderLogin);
  route('/inscription', renderRegister);
  route('/tableau-de-bord', renderDashboard);
  route('/profil', renderProfile);
  route('/parametres', renderSettings);
  route('/portefeuille', renderWallet);
  route('/missions', renderMissions);
  route('/historique', renderHistory);
  route('/jouer', renderPlay);
  route('/partie/:id', renderRoom);
  route('/achat', renderPurchase);
  route('/regles', renderRules);
}

async function main() {
  captureInvite();

  if (!isConfigured) {
    configWarning();
    return;
  }

  registerRoutes();

  let user = await getUser();
  let username = await loadUsername(user);
  if (user) await syncServerClock();
  updateShell(user, username);

  onAuthChange(async (event, nextUser) => {
    if (event === 'SIGNED_OUT') {
      user = null;
      username = '';
      updateShell(null);
      navigate('/');
      return;
    }

    if (nextUser && nextUser.id !== user?.id) {
      user = nextUser;
      username = await loadUsername(user);
      await syncServerClock();
      updateShell(user, username);
      if (pendingCode()) await resumePendingRoom(user);
    }
  });

  window.addEventListener('hashchange', () => updateShell(user, username));

  startRouter();

  if (user && pendingCode()) {
    await resumePendingRoom(user);
  }
}

main().catch((error) => {
  console.error(error);
  app.innerHTML = `<div class="alert alert--error">Impossible de démarrer l’application : ${escapeHtml(error?.message || error)}</div>`;
});
