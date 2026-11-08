/* =====================================================================
   En-tête, navigation et pied de page.
   ===================================================================== */
import { signOut } from '../auth.js';
import { currentPath, navigate } from '../router.js';
import { escapeHtml, initials } from '../utils.js';

const GUEST_NAV = [
  { href: '/', label: 'Accueil' },
  { href: '/regles', label: 'Règles' },
  { href: '/connexion', label: 'Connexion' },
  { href: '/inscription', label: 'Inscription' }
];

const USER_NAV = [
  { href: '/tableau-de-bord', label: 'Tableau de bord' },
  { href: '/jouer', label: 'Jouer' },
  { href: '/missions', label: 'Missions' },
  { href: '/portefeuille', label: 'Portefeuille' },
  { href: '/historique', label: 'Historique' },
  { href: '/profil', label: 'Profil' }
];

const MOBILE_GUEST = [
  { href: '/', label: 'Accueil', icon: '◉' },
  { href: '/regles', label: 'Règles', icon: '☰' },
  { href: '/connexion', label: 'Connexion', icon: '→' },
  { href: '/inscription', label: 'Inscription', icon: '✦' }
];

const MOBILE_USER = [
  { href: '/tableau-de-bord', label: 'Accueil', icon: '◉' },
  { href: '/jouer', label: 'Jouer', icon: '▶' },
  { href: '/missions', label: 'Missions', icon: '✦' },
  { href: '/portefeuille', label: 'Crédits', icon: '◈' },
  { href: '/profil', label: 'Profil', icon: '☺' }
];

function isActive(href, path) {
  if (href === '/') return path === '/';
  return path === href || path.startsWith(`${href}/`);
}

export function updateShell(user, username) {
  const path = currentPath();
  const nav = user ? USER_NAV : GUEST_NAV;
  const mobile = user ? MOBILE_USER : MOBILE_GUEST;

  const mainNav = document.getElementById('main-nav');
  if (mainNav) {
    mainNav.innerHTML = nav
      .map((item) => `<a href="#${item.href}" ${isActive(item.href, path) ? 'aria-current="page"' : ''}>${escapeHtml(item.label)}</a>`)
      .join('');
  }

  const mobileNav = document.getElementById('mobile-nav');
  if (mobileNav) {
    mobileNav.innerHTML = mobile
      .map((item) => `
        <a href="#${item.href}" ${isActive(item.href, path) ? 'aria-current="page"' : ''}>
          <span class="icon" aria-hidden="true">${item.icon}</span>
          <span>${escapeHtml(item.label)}</span>
        </a>`)
      .join('');
  }

  const headerUser = document.getElementById('header-user');
  if (!headerUser) return;

  if (!user) {
    headerUser.innerHTML = `<a class="btn btn--gold btn--sm" href="#/connexion">Se connecter</a>`;
    return;
  }

  const name = username || user.email?.split('@')[0] || 'Joueur';
  headerUser.innerHTML = `
    <span class="avatar" aria-hidden="true">${escapeHtml(initials(name))}</span>
    <span class="hide-sm">${escapeHtml(name)}</span>
    <button class="btn btn--ghost btn--sm" type="button" id="logout-btn">Quitter</button>`;

  headerUser.querySelector('#logout-btn')?.addEventListener('click', async () => {
    await signOut();
    navigate('/');
  });
}
