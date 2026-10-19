# Supabase de OpsFlow

## `actual/`
Copia de referencia de los scripts que ya están pegados en Supabase (`1-PEGAR` … `33-PEGAR`, tomados de Descargas el 19/10/2026).
Se numeran con dos cifras para que salgan en orden. **No se vuelven a ejecutar**: sirven para leer el backend real y comparar.
Pendiente: confirmar con un volcado del esquema real (solo estructura) que producción coincide con estos archivos.

## `pruebas/00-MONTAR-proyecto_pruebas.sql`
Monta en un proyecto Supabase **nuevo y vacío** todo el backend 1–33 de una vez (001_cuentas + scripts sin pruebas).
Diferencias con `actual/`: no incluye el 19 ni el apartado 5 del 23, porque programan tareas cron que llaman a las
funciones de **producción**.

**Marca de entorno.** En la primera línea se escribe el identificador del proyecto de pruebas (20 letras; sale en la
dirección `supabase.com/dashboard/project/<identificador>`). El script crea la tabla `opsflow_entorno` con
`tipo = 'pruebas'` y ese identificador. Se para si falta el identificador, si es el de producción
(`zxsiantglodsqqvigndk`) o si la base ya tiene OpsFlow.

## `migraciones/`
Cambios nuevos, en el mismo estilo (`NN-PEGAR-….sql` + `NN-PEGAR-pruebas_….sql`).
**Solo en el proyecto de PRUEBAS.** Cada script empieza con una línea donde se escribe el identificador del proyecto
y se para sin cambiar nada si:
- no se escribió, o es el de producción;
- la base no tiene la marca `opsflow_entorno` con `tipo = 'pruebas'` (producción no la tiene);
- el identificador escrito no coincide con el de la marca;
- hay propiedades reales.

Para producción hará falta autorización expresa del dueño y una marca de entorno propia: no se hace todavía.

| Script | Qué hace |
|---|---|
| `34-PEGAR-permisos_sustituciones.sql` | OPS-GLOBAL-AUD-001: solo el líder de Limpieza asigna cleaners (asignar, publicar, equipos, hora de entrada) y solo el líder de Drivers asigna drivers y suelta tareas asignadas. Operación ya no asigna ni suelta. OPS-ADM-001: tabla `sustituciones`; Operación nombra a un operador del mismo departamento, con fechas. El sustituto **suma** las facultades del líder de su departamento (asignar, lo que ve el líder, sus avisos) y **conserva** su trabajo de operador; su nivel no cambia. Una restricción de la tabla impide sustituciones solapadas aunque lleguen dos peticiones a la vez. Errores con código: `42501` sin permiso, `22023` dato no válido, `23P01` solape. |
| `35-PEGAR-pruebas_permisos.sql` | 23 comprobaciones. Todas deben decir OK. **No deja nada**: todo se hace dentro de un bloque que se deshace al final, sin borrar datos de nadie. Las pruebas de "no puede" comprueban el código y el motivo exactos. |
| `generador-34/` | La parte 5 de la 34 se genera a partir de la última versión de cada función y regla de lectura del backend 1–33 (`00-MONTAR`), cambiando solo "líder de X" por `_es_lider('X')`: `python3 supabase/migraciones/generador-34/gen34.py . supabase/migraciones/generador-34` |

## Cómo probar 34 y 35 (proyecto Supabase de PRUEBAS)
1. Crear un proyecto Supabase **nuevo y vacío** (no producción). Copiar su identificador de la dirección.
2. SQL Editor → pegar `00-MONTAR` → escribir el identificador en la primera línea → Run.
3. Pegar la 34 → escribir el mismo identificador → Run.
4. Pegar la 35 → mismo identificador → Run: las 23 filas deben decir OK.
5. Pegar otra vez la 34 y la 35: debe funcionar igual (se pueden repetir).

Usar el SQL Editor (un solo Run por archivo): si algo falla, Postgres no ejecuta el resto del archivo.

Pruebas locales sin Supabase: `node tests/permisos.test.cjs`.
