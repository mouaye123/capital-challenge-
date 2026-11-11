/* =====================================================================
   Configuration Supabase
   ---------------------------------------------------------------------
   Remplacez les deux valeurs ci-dessous par celles de votre projet :
   Supabase → Project Settings → API.
   N'utilisez QUE la clé publique « anon / publishable ».
   Ne mettez JAMAIS la clé service_role dans ce fichier.
   ===================================================================== */

export const SUPABASE_URL = "https://zsrjjgqowwhifmgevfkd.supabase.co";
export const SUPABASE_ANON_KEY = "sb_publishable_aJrbAPwGSsJdiu4JqRwfOw_6DsrKywu";

// Version du client chargée dans index.html (doit rester identique).
export const SUPABASE_JS_VERSION = '2.45.4';

export const isConfigured =
  !SUPABASE_URL.includes('VOTRE-PROJET') &&
  !SUPABASE_ANON_KEY.includes('VOTRE_CLE') &&
  SUPABASE_URL.startsWith('https://');

/* =====================================================================
   Interrupteur de la boutique de crédits.
   ---------------------------------------------------------------------
   false = achats fermés : la page /achat affiche « Boutique fermée »,
           aucun bouton d'achat n'est rendu, et le serveur refuse aussi
           l'appel create_purchase (voir supabase/sql/07_correctif.sql).
   true  = boutique ouverte (à réactiver une fois le paiement vérifié).
   ===================================================================== */
export const PURCHASES_ENABLED = false;
