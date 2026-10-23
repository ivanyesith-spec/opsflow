// OpsFlow · Edge Function `gestionar-cuenta`
// Acciones: 'resetear' | 'desactivar' | 'reactivar' sobre otra cuenta. Solo perfiles activos 'operacion'.
// Nadie puede gestionar su propia cuenta desde aquí (evita que un administrador se bloquee por error).
// Respuesta OK resetear: { ok: true, nombre, correo, idioma, clave }
// Respuesta OK resto:    { ok: true }
// Respuesta error:       { ok: false, error: "mensaje" } con 400/401/403/404/405/500

import { createClient } from 'npm:@supabase/supabase-js@2';

const ORIGENES = [
  'https://opsflow-piloto-pruebas.vercel.app',
  'https://ivanyesith-spec.github.io',
];
const ACCIONES = ['resetear', 'desactivar', 'reactivar'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BLOQUEO = '876000h'; // ~100 años: la cuenta no puede iniciar sesión

function cors(req: Request): Record<string, string> {
  const o = req.headers.get('origin') ?? '';
  return {
    'Access-Control-Allow-Origin': ORIGENES.includes(o) ? o : ORIGENES[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
}
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), 'Content-Type': 'application/json' } });
const fallo = (req: Request, status: number, error: string) => json(req, status, { ok: false, error });

function claveTemporal(): string {
  const abc = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  const buf = new Uint32Array(12);
  crypto.getRandomValues(buf);
  return Array.from(buf, n => abc[n % abc.length]).join('');
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== 'POST') return fallo(req, 405, 'Método no permitido.');

  const url = Deno.env.get('SUPABASE_URL');
  const servicio = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !servicio) {
    console.error('gestionar-cuenta: faltan variables de entorno del servidor');
    return fallo(req, 500, 'Error de configuración del servidor.');
  }
  const admin = createClient(url, servicio, { auth: { persistSession: false, autoRefreshToken: false } });

  // 1. ¿Quién llama?
  const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!token) return fallo(req, 401, 'Sesión no válida. Vuelve a entrar.');
  const { data: quien, error: errQuien } = await admin.auth.getUser(token);
  if (errQuien || !quien?.user) return fallo(req, 401, 'Sesión no válida. Vuelve a entrar.');

  // 2. ¿Tiene permiso?
  const { data: yo, error: errYo } = await admin
    .from('perfiles').select('id, nivel, activo').eq('id', quien.user.id).maybeSingle();
  if (errYo) { console.error('gestionar-cuenta: lectura perfil', errYo.message); return fallo(req, 500, 'No se pudo comprobar tu perfil.'); }
  if (!yo || !yo.activo || yo.nivel !== 'operacion') return fallo(req, 403, 'No tienes permiso para gestionar cuentas.');

  // 3. Validar petición
  let d: Record<string, unknown>;
  try { d = await req.json(); } catch { return fallo(req, 400, 'Datos no válidos.'); }
  const accion = String(d.accion ?? '');
  const id = String(d.id ?? '');
  if (!ACCIONES.includes(accion)) return fallo(req, 400, 'Acción no válida.');
  if (!UUID.test(id)) return fallo(req, 400, 'Cuenta no válida.');
  if (id === yo.id) return fallo(req, 400, 'No puedes gestionar tu propia cuenta.');

  const { data: p, error: errP } = await admin
    .from('perfiles').select('id, nombre, idioma, activo').eq('id', id).maybeSingle();
  if (errP) { console.error('gestionar-cuenta: lectura destino', errP.message); return fallo(req, 500, 'No se pudo leer la cuenta.'); }
  if (!p) return fallo(req, 404, 'La cuenta no existe.');

  // 4. Acciones
  if (accion === 'resetear') {
    if (!p.activo) return fallo(req, 400, 'La cuenta está desactivada. Reactívala antes de resetear.');
    const { data: u, error: errU } = await admin.auth.admin.getUserById(id);
    if (errU || !u?.user) return fallo(req, 404, 'La cuenta no tiene acceso asociado.');
    const clave = claveTemporal();
    const { error: errClave } = await admin.auth.admin.updateUserById(id, { password: clave });
    if (errClave) { console.error('gestionar-cuenta: reset', errClave.message); return fallo(req, 500, 'No se pudo resetear la contraseña.'); }
    const { error: errMarca } = await admin.from('perfiles').update({ debe_cambiar_clave: true }).eq('id', id);
    if (errMarca) console.error('gestionar-cuenta: marcar debe_cambiar_clave', errMarca.message);
    console.log('gestionar-cuenta: resetear', { id, por: yo.id });
    return json(req, 200, { ok: true, nombre: p.nombre, correo: u.user.email, idioma: p.idioma, clave });
  }

  if (accion === 'desactivar') {
    if (!p.activo) return json(req, 200, { ok: true }); // ya estaba desactivada
    const { error: errBan } = await admin.auth.admin.updateUserById(id, { ban_duration: BLOQUEO });
    if (errBan) { console.error('gestionar-cuenta: bloquear', errBan.message); return fallo(req, 500, 'No se pudo bloquear el acceso.'); }
    const { error: errAct } = await admin.from('perfiles')
      .update({ activo: false, desactivado_en: new Date().toISOString() }).eq('id', id);
    if (errAct) {
      console.error('gestionar-cuenta: desactivar perfil', errAct.message);
      await admin.auth.admin.updateUserById(id, { ban_duration: 'none' }); // compensación
      return fallo(req, 500, 'No se pudo desactivar la cuenta.');
    }
    console.log('gestionar-cuenta: desactivar', { id, por: yo.id });
    return json(req, 200, { ok: true });
  }

  // reactivar
  if (p.activo) return json(req, 200, { ok: true });
  const { error: errUnban } = await admin.auth.admin.updateUserById(id, { ban_duration: 'none' });
  if (errUnban) { console.error('gestionar-cuenta: desbloquear', errUnban.message); return fallo(req, 500, 'No se pudo restablecer el acceso.'); }
  const { error: errRe } = await admin.from('perfiles').update({ activo: true, desactivado_en: null }).eq('id', id);
  if (errRe) {
    console.error('gestionar-cuenta: reactivar perfil', errRe.message);
    await admin.auth.admin.updateUserById(id, { ban_duration: BLOQUEO }); // compensación
    return fallo(req, 500, 'No se pudo reactivar la cuenta.');
  }
  console.log('gestionar-cuenta: reactivar', { id, por: yo.id });
  return json(req, 200, { ok: true });
});
