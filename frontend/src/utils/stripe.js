import { loadStripe } from "@stripe/stripe-js";

const publishableKey = import.meta.env.VITE_STRIPE_PUBLIC_KEY;

/**
 * Stripe is optional. When no publishable key is configured the checkout
 * falls back to a demo payment form that creates the order directly.
 */
export const isStripeConfigured = Boolean(publishableKey);

const stripePromise = isStripeConfigured ? loadStripe(publishableKey) : null;

export default stripePromise;
