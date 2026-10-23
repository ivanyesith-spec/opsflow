// OpsFlow · Edge Function `crear-cuenta`
// Crea una cuenta (auth.users + public.perfiles). Solo para perfiles activos de nivel 'operacion'.
// La clave de servicio vive SOLO aqui, en el servidor (variable de entorno de Supabase).
// Respuesta OK:    { ok: true, id, clave }        (clave temporal, se muestra una vez)
// Respuesta error: { ok: false, error: "mensaje" } con 400/401/403/405/409/500

import { createClient } from 'npm:@supabase/supabase-js@2';

const ORIGENES = [
  'https://opsflow-piloto-pruebas.vercel.app',
  'https://ivanyesith-spec.github.io',
];
const DEPARTAMENTOS = ['Limpieza', 'Linens', 'Drivers', 'Operación'];
const NIVELES = ['operador', 'lider', 'operacion'];
const ZONAS = ['Norte', 'Centro', 'Sur'];
const IDIOMAS = ['en', 'es'];

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

// Clave temporal: 12 caracteres sin letras confusas (0/O, 1/l/I)
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
    console.error('crear-cuenta: faltan variables de entorno del servidor');
    return fallo(req, 500, 'Error de configuración del servidor.');
  }
  const admin = createClient(url, servicio, { auth: { persistSession: false, autoRefreshToken: false } });

  // 1. ¿Quién llama? (JWT de la sesión)
  const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!token) return fallo(req, 401, 'Sesión no válida. Vuelve a entrar.');
  const { data: quien, error: errQuien } = await admin.auth.getUser(token);
  if (errQuien || !quien?.user) return fallo(req, 401, 'Sesión no válida. Vuelve a entrar.');

  // 2. ¿Tiene permiso? Perfil activo y nivel 'operacion', comprobado en la base de datos
  const { data: yo, error: errYo } = await admin
    .from('perfiles').select('id, nivel, activo').eq('id', quien.user.id).maybeSingle();
  if (errYo) { console.error('crear-cuenta: lectura perfil', errYo.message); return fallo(req, 500, 'No se pudo comprobar tu perfil.'); }
  if (!yo || !yo.activo || yo.nivel !== 'operacion') return fallo(req, 403, 'No tienes permiso para crear cuentas.');

  // 3. Validar datos
  let d: Record<string, unknown>;
  try { d = await req.json(); } catch { return fallo(req, 400, 'Datos no válidos.'); }
  const nombre = String(d.nombre ?? '').trim().replace(/\s+/g, ' ');
  const correo = String(d.correo ?? '').trim().toLowerCase();
  const departamento = String(d.departamento ?? '');
  const nivel = String(d.nivel ?? '');
  const zona = d.zona == null || d.zona === '' ? null : String(d.zona);
  const idioma = String(d.idioma ?? 'en');

  if (nombre.length < 2 || nombre.length > 80) return fallo(req, 400, 'El nombre debe tener entre 2 y 80 caracteres.');
  if (correo.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(correo)) return fallo(req, 400, 'El correo no es válido.');
  if (!DEPARTAMENTOS.includes(departamento)) return fallo(req, 400, 'Departamento no válido.');
  if (!NIVELES.includes(nivel)) return fallo(req, 400, 'Nivel no válido.');
  if (zona !== null && !ZONAS.includes(zona)) return fallo(req, 400, 'Zona no válida.');
  if (!IDIOMAS.includes(idioma)) return fallo(req, 400, 'Idioma no válido.');
  // Combinaciones coherentes (las mismas reglas que ayuda a cumplir el formulario)
  if ((nivel === 'operacion') !== (departamento === 'Operación'))
    return fallo(req, 400, 'El nivel Operación va solo con el departamento Operación.');
  if (nivel === 'operador' && !zona) return fallo(req, 400, 'Un operador necesita zona.');
  if (nivel !== 'operador' && zona) return fallo(req, 400, 'Líderes y Operación no llevan zona.');

  // 4. Crear el usuario de acceso
  const clave = claveTemporal();
  const { data: nuevo, error: errAlta } = await admin.auth.admin.createUser({
    email: correo, password: clave, email_confirm: true, user_metadata: { nombre },
  });
  if (errAlta || !nuevo?.user) {
    const msg = errAlta?.message ?? '';
    if (/already|registered|exists/i.test(msg)) return fallo(req, 409, 'Ya existe una cuenta con ese correo.');
    console.error('crear-cuenta: createUser', errAlta?.status, msg); // nunca se registra la clave
    return fallo(req, 500, 'No se pudo crear el acceso.');
  }

  // 5. Crear el perfil. Si falla, se deshace el usuario (compensación)
  const { error: errPerfil } = await admin.from('perfiles').insert({
    id: nuevo.user.id, nombre, departamento, nivel, zona, idioma,
    activo: true, debe_cambiar_clave: true, creado_por: yo.id,
  });
  if (errPerfil) {
    console.error('crear-cuenta: insert perfil', errPerfil.message);
    const { error: errBorrar } = await admin.auth.admin.deleteUser(nuevo.user.id);
    if (errBorrar) console.error('crear-cuenta: COMPENSACION FALLIDA, usuario huerfano', nuevo.user.id, errBorrar.message);
    return fallo(req, 500, 'No se pudo crear el perfil. No se ha creado ninguna cuenta.');
  }

  console.log('crear-cuenta: ok', { id: nuevo.user.id, por: yo.id, departamento, nivel });
  return json(req, 200, { ok: true, id: nuevo.user.id, clave });
});
