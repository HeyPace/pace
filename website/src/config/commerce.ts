/**
 * Checkout URLs for the marketing site.
 *
 * Set `PUBLIC_PACE_CHECKOUT_URL` at Cloudflare Pages build time when a
 * hosted checkout exists. Until then, the mailto fallback is the current
 * manual purchase path; a product can be paid without pretending that an
 * automated checkout or in-app licence system exists.
 */
const paceMailtoCheckout =
  "mailto:hi@sarthakagrawal.dev?subject=Buy%20Pace%20(%2429)&body=Hi%20Sarthak%2C%20I%27d%20like%20to%20buy%20Pace%20for%20%2429.%20My%20Mac%20model%20is%3A%20";

export const studioInterestURL =
  "mailto:hi@sarthakagrawal.dev?subject=Pace%20Studio%20interest&body=Hi%20Sarthak%2C%20please%20let%20me%20know%20when%20Pace%20Studio%20is%20available.";

export const paceCheckoutURL =
  import.meta.env.PUBLIC_PACE_CHECKOUT_URL ?? paceMailtoCheckout;

export const paceCheckoutIsMailto = paceCheckoutURL.startsWith("mailto:");
