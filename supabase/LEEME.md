# Supabase de OpsFlow

## `actual/`
Copia de referencia de los scripts que ya están pegados en Supabase (`1-PEGAR` … `33-PEGAR`, tomados de Descargas el 19/10/2026).
Se numeran con dos cifras para que salgan en orden. **No se vuelven a ejecutar**: sirven para leer el backend real y comparar.
Pendiente: confirmar con un volcado del esquema real (solo estructura) que producción coincide con estos archivos.

## `migraciones/`
Cambios nuevos, en el mismo estilo (`NN-PEGAR-….sql` + `NN-PEGAR-pruebas_….sql`).
Primero en un proyecto Supabase de **PRUEBAS**; en producción solo con autorización expresa.

| Script | Qué hace |
|---|---|
| `34-PEGAR-permisos_sustituciones.sql` | OPS-GLOBAL-AUD-001: solo el líder de Limpieza asigna cleaners (asignar, publicar, equipos, hora de entrada) y solo el líder de Drivers asigna drivers. Operación ya no asigna. OPS-ADM-001: tabla `sustituciones`; Operación nombra a un operador del mismo departamento, con fechas, que actúa como líder solo en ese periodo. |
| `35-PEGAR-pruebas_permisos.sql` | 17 comprobaciones de lo anterior. Todas deben decir OK. |

Pruebas locales sin Supabase: `node tests/permisos.test.cjs`.
