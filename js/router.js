/* =====================================================================
   Routeur minimal basé sur le hash (#/chemin).
   Compatible GitHub Pages : aucune réécriture serveur nécessaire.
   ===================================================================== */
const routes = [];
let cleanup = null;

export function route(pattern, handler) {
  routes.push({
    segments: pattern.split('/').filter(Boolean),
    handler
  });
}

export function navigate(path, { replace = false } = {}) {
  const target = `#${path.startsWith('/') ? path : `/${path}`}`;
  if (window.location.hash === target) {
    render();
    return;
  }
  if (replace) {
    window.history.replaceState(null, '', target);
    render();
  } else {
    window.location.hash = target;
  }
}

export function currentPath() {
  return window.location.hash.replace(/^#/, '') || '/';
}

function match(segments) {
  const parts = currentPath().split('/').filter(Boolean);
  if (parts.length !== segments.length) return null;
  const params = {};
  for (let i = 0; i < segments.length; i += 1) {
    if (segments[i].startsWith(':')) {
      params[segments[i].slice(1)] = decodeURIComponent(parts[i]);
    } else if (segments[i] !== parts[i]) {
      return null;
    }
  }
  return params;
}

export async function render() {
  if (typeof cleanup === 'function') {
    try { cleanup(); } catch { /* ignore */ }
    cleanup = null;
  }

  const app = document.getElementById('app');
  if (!app) return;

  let found = null;
  let params = null;
  for (const r of routes) {
    params = match(r.segments);
    if (params) { found = r; break; }
  }

  if (!found) {
    navigate('/', { replace: true });
    return;
  }

  app.innerHTML = '';
  try {
    const result = await found.handler(app, params);
    if (typeof result === 'function') cleanup = result;
  } catch (error) {
    console.error(error);
    app.innerHTML = `
      <div class="container-mid">
        <div class="alert alert--error">
          <strong>Une erreur est survenue.</strong><br>
          ${error?.message ? String(error.message).replaceAll('<', '&lt;') : 'Veuillez réessayer.'}
        </div>
        <p class="mt-4"><a class="btn btn--ghost" href="#/">Retour à l’accueil</a></p>
      </div>`;
  }
  window.scrollTo({ top: 0, behavior: 'instant' in window ? 'instant' : 'auto' });
}

export function startRouter() {
  window.addEventListener('hashchange', render);
  render();
}
