# OpsFlow · Diagnóstico y corrección de cuentas (piloto)

**Fecha:** 23/10/2026 · **Estado:** código listo, **pendiente de desplegar y probar** (sin acceso a Supabase/Vercel desde esta sesión).

## Hallazgos comprobados

| # | Hallazgo | Cómo se comprobó |
|---|----------|------------------|
| 1 | El piloto en Vercel usa el Supabase de **pruebas** (`yxgilbgwuxmlbdrbfisi`). | Código servido por `opsflow-piloto-pruebas.vercel.app` |
| 2 | En pruebas **no existe ninguna** de las 5 funciones que llama la app: `crear-cuenta`, `gestionar-cuenta`, `avisar`, `ruta`, `geocodificar` (HTTP 404 "Requested function was not found"). Solo existe `opsflow-piloto` (410). | Llamada GET a cada función |
| 3 | En el Supabase **principal** (`zxsiantglodsqqvigndk`) las 5 funciones **sí existen** (responden 405 a GET). El proyecto de pruebas se creó sin copiarlas. | Llamada GET a cada función |
| 4 | El código del piloto **no está en GitHub**: `main` solo tiene `index.html` apuntando al proyecto principal (título "OpsFlow"); Vercel sirve otra versión ("OpsFlow · PILOTO DE PRUEBAS"). No hay rama de piloto. | Clon de `main` vs página publicada |
| 5 | El código de las funciones no está en el repositorio (no hay carpeta `supabase/functions`). | Clon de `main` |
| 6 | El piloto genera el mensaje de WhatsApp con el enlace de **producción** (`APP_URL = ivanyesith-spec.github.io/opsflow/`): una cuenta de prueba recibiría el enlace equivocado. | Código servido por Vercel |

**Causa del fallo:** las funciones `crear-cuenta` y `gestionar-cuenta` no están desplegadas en el proyecto de pruebas. Lo mismo rompe avisos (`avisar`), rutas (`ruta`) y geocodificación en el piloto.

## Archivos nuevos

- `supabase/functions/crear-cuenta/index.ts`
- `supabase/functions/gestionar-cuenta/index.ts`

Ambos: verifican la sesión con `auth.getUser()`, exigen perfil **activo + nivel `operacion`** en la base de datos (401/403), validan todos los campos y combinaciones, usan la clave de servicio solo en el servidor, no registran contraseñas, compensan si falla el segundo paso (borran el usuario creado / deshacen el bloqueo), impiden gestionar la propia cuenta y limitan CORS a Vercel piloto y GitHub Pages. No se toca RLS.

Contrato respetado con el frontend actual (sin cambios en `index.html`):
- `crear-cuenta` → `{ ok, id, clave }`
- `gestionar-cuenta` (`resetear` | `desactivar` | `reactivar`) → `{ ok }`; `resetear` añade `nombre, correo, idioma, clave`
- Errores → `{ ok:false, error }`, que la app ya muestra.

Desactivar bloquea además el inicio de sesión (ban en Auth), no solo el perfil.

## Pruebas — ninguna ejecutada todavía

| Prueba | Estado |
|---|---|
| Admin (operacion) ve "+ Crear cuenta" | No ejecutada |
| Alta de usuario de prueba Linens → auth.users + perfiles | No ejecutada |
| Usuario sin `operacion` recibe 403 | No ejecutada |
| Resetear / desactivar / reactivar | No ejecutada |
| Limpieza de cuentas de prueba | No ejecutada |

## Pendientes a decidir

1. Copiar a pruebas también `avisar`, `ruta`, `geocodificar` (desde el proyecto principal) si el piloto debe probarlas.
2. Subir el `index.html` del piloto a GitHub (rama `piloto`) para que lo publicado tenga origen controlado.
3. Cambiar `APP_URL` del piloto a `https://opsflow-piloto-pruebas.vercel.app/`.
4. Decidir si un `operacion` puede crear otras cuentas `operacion` (hoy sí, como en la interfaz).
