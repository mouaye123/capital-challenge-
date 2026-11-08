/* =====================================================================
   Écrans de connexion et d'inscription.
   ===================================================================== */
import { signIn, signUp } from '../auth.js';
import { navigate } from '../router.js';
import { getGameConfig } from '../gameConfig.js';
import { formatCredits, friendlyError, toast } from '../utils.js';
import { resumePendingRoom } from '../sessionFlow.js';

function authShell({ title, subtitle, body, footer }) {
  return `
    <div class="auth-wrap">
      <div class="auth-card card">
        <h1>${title}</h1>
        <p class="muted">${subtitle}</p>
        ${body}
        <div class="auth-switch">${footer}</div>
        <p class="tiny muted" style="margin-top:18px">
          En continuant, vous acceptez que les crédits soient virtuels, non retirables
          et non convertibles en argent réel.
        </p>
      </div>
    </div>`;
}

export function renderLogin(root) {
  root.innerHTML = authShell({
    title: 'Connexion',
    subtitle: 'Retrouvez vos parties, votre portefeuille et vos missions.',
    body: `
      <form id="login-form" class="stack" novalidate>
        <div class="alert alert--error hidden" id="form-error" role="alert"></div>
        <div class="field">
          <label for="email">Adresse e-mail</label>
          <input class="input" id="email" name="email" type="email" autocomplete="email"
                 placeholder="vous@exemple.com" required>
        </div>
        <div class="field">
          <label for="password">Mot de passe</label>
          <input class="input" id="password" name="password" type="password"
                 autocomplete="current-password" placeholder="Votre mot de passe" required>
        </div>
        <button class="btn btn--gold btn--block btn--lg" type="submit" id="submit-btn">
          Se connecter
        </button>
      </form>`,
    footer: `Pas encore de compte ? <a href="#/inscription">Créer un compte</a>`
  });

  const form = root.querySelector('#login-form');
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const errorBox = root.querySelector('#form-error');
    const button = root.querySelector('#submit-btn');
    errorBox.classList.add('hidden');

    const email = form.email.value.trim();
    const password = form.password.value;
    if (!email || !password) {
      errorBox.textContent = 'Renseignez votre e-mail et votre mot de passe.';
      errorBox.classList.remove('hidden');
      return;
    }

    button.disabled = true;
    button.textContent = 'Connexion…';
    try {
      const data = await signIn({ email, password });
      toast('Connexion réussie. Bon jeu !', 'success');
      const resumed = await resumePendingRoom(data.user);
      if (!resumed) navigate('/tableau-de-bord');
    } catch (error) {
      errorBox.textContent = friendlyError(error);
      errorBox.classList.remove('hidden');
      button.disabled = false;
      button.textContent = 'Se connecter';
    }
  });
}

export async function renderRegister(root) {
  const config = await getGameConfig();

  root.innerHTML = authShell({
    title: 'Créer un compte',
    subtitle: `Un pseudo, un e-mail, un mot de passe : ${formatCredits(config.welcome_bonus)} crédits vous attendent.`,
    body: `
      <form id="register-form" class="stack" novalidate>
        <div class="alert alert--error hidden" id="form-error" role="alert"></div>
        <div class="alert alert--success hidden" id="form-success" role="status"></div>
        <div class="field">
          <label for="username">Pseudo</label>
          <input class="input" id="username" name="username" type="text" autocomplete="nickname"
                 minlength="3" maxlength="20" placeholder="Ex. Mouaye" required>
          <span class="field__hint">3 à 20 caractères, visible par les autres joueurs.</span>
        </div>
        <div class="field">
          <label for="email">Adresse e-mail</label>
          <input class="input" id="email" name="email" type="email" autocomplete="email"
                 placeholder="vous@exemple.com" required>
        </div>
        <div class="field">
          <label for="password">Mot de passe</label>
          <input class="input" id="password" name="password" type="password"
                 autocomplete="new-password" minlength="6" placeholder="6 caractères minimum" required>
        </div>
        <div class="field">
          <label for="password2">Confirmer le mot de passe</label>
          <input class="input" id="password2" name="password2" type="password"
                 autocomplete="new-password" placeholder="Répétez le mot de passe" required>
        </div>
        <button class="btn btn--gold btn--block btn--lg" type="submit" id="submit-btn">
          Créer mon compte
        </button>
      </form>`,
    footer: `Déjà inscrit ? <a href="#/connexion">Se connecter</a>`
  });

  const form = root.querySelector('#register-form');
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const errorBox = root.querySelector('#form-error');
    const successBox = root.querySelector('#form-success');
    const button = root.querySelector('#submit-btn');
    errorBox.classList.add('hidden');
    successBox.classList.add('hidden');

    const username = form.username.value.trim();
    const email = form.email.value.trim();
    const password = form.password.value;
    const password2 = form.password2.value;

    const fail = (message) => {
      errorBox.textContent = message;
      errorBox.classList.remove('hidden');
    };

    if (username.length < 3 || username.length > 20) return fail('Le pseudo doit contenir entre 3 et 20 caractères.');
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return fail('Adresse e-mail invalide.');
    if (password.length < 6) return fail('Le mot de passe doit contenir au moins 6 caractères.');
    if (password !== password2) return fail('Les deux mots de passe ne correspondent pas.');

    button.disabled = true;
    button.textContent = 'Création…';
    try {
      const data = await signUp({ email, password, username });
      if (data.session) {
        toast(`Compte créé. Vos ${formatCredits(config.welcome_bonus)} crédits sont disponibles.`, 'success');
        const resumed = await resumePendingRoom(data.user);
        if (!resumed) navigate('/tableau-de-bord');
      } else {
        successBox.innerHTML = 'Compte créé. <strong>Vérifiez votre boîte e-mail</strong> pour confirmer votre adresse, puis connectez-vous.';
        successBox.classList.remove('hidden');
        button.disabled = true;
        button.textContent = 'En attente de confirmation';
      }
    } catch (error) {
      fail(friendlyError(error));
      button.disabled = false;
      button.textContent = 'Créer mon compte';
    }
  });
}
