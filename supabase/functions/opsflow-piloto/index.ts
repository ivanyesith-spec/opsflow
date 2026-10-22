// ENLACE ANTIGUO DESACTIVADO: el dominio compartido de Supabase fuerza text/plain.
// Esta Edge Function nunca debe servir el frontend de OpsFlow.
// La interfaz piloto se alojará por HTTPS en un hosting estático (Vercel).
Deno.serve(() => new Response(
  "OpsFlow — Piloto de pruebas\n\nEste enlace se ha desactivado porque Supabase no permite mostrar páginas HTML en su dominio estándar.\nLa aplicación se trasladará a una dirección HTTPS de Vercel, conectada solamente al proyecto de pruebas.\nNo introduzcas contraseñas en este enlace.\n",
  { status: 410, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store", "X-Robots-Tag":"noindex, nofollow" } }
));
