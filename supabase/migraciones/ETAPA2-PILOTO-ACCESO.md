# OpsFlow · Piloto aislado de la Etapa 2 (22-10-2026)

**Estado:** Configurado en la rama `piloto-norte-3dep` y publicado como sitio web independiente en Vercel.

**URL del piloto (Vercel):** https://opsflow-piloto-pruebas.vercel.app

**Despliegue Vercel confirmado READY:** `dpl_4hpiDsihpRDDXm6RBiU72HNxxVLn`, fuente `piloto-norte-3dep`, commit `f197cf82c03d23722a0b4534748376965e1f7047`. La antigua URL Supabase devolvía el HTML como texto plano; se desactivó y no debe utilizarse.

La URL es pública para mostrar la pantalla de acceso; **ninguna operación se puede realizar sin una cuenta autenticada con permisos**. No se deben publicar contraseñas ni secretos en GitHub.

## Protección del entorno
- El archivo `index.html` de **esta rama** está vinculado exclusivamente al proyecto Supabase de pruebas `yxgilbgwuxmlbdrbfisi`.
- Utiliza una clave **publicable**; nunca se carga una clave administrativa.
- Verifica el identificador de proyecto antes de iniciar Supabase; si no coincide, se bloquea.
- Muestra siempre una franja «🧪 PILOTO DE PRUEBAS».
- Aísla el almacenamiento local mediante el prefijo `opsflow-piloto-` y las sesiones en `sessionStorage`.
- Desactiva el registro del Service Worker y los avisos push para evitar interferencias con la aplicación principal.
- La rama `main` y la base de datos `opsflow` **no se modifican**.

**Importante:** el alojamiento es un proyecto Vercel separado de `opsflow` y conectado exclusivamente al proyecto Supabase de pruebas. Vercel tiene habilitada la protección de acceso; el usuario puede necesitar iniciar sesión en Vercel antes de ver el piloto. Siguen desactivados los avisos push y la PWA; cámara y QR requieren prueba en móvil.

## Estado verificado
- Migración 36 instalada en Supabase de pruebas.
- SQL 37: 22/22 comprobaciones OK, con reversión de datos de prueba.
- Chromium: siete pruebas de interfaz OK utilizando Supabase simulado.
- Se añadieron pruebas de bloqueo contra conexiones a producción.
- **Sin usuarios piloto por ahora:** la última comprobación mostró 0 cuentas Auth y 0 perfiles.

## Alta de cuentas ficticias (pendiente: Auth tiene cero usuarios)
1. Entrar al Dashboard de Supabase y **verificar** el project ref `yxgilbgwuxmlbdrbfisi`.
2. En **Authentication → Users**, crear tres cuentas con correos de prueba controlados
   por su propietario. Usar contraseñas individuales que no se compartan por chat ni GitHub.
   No utilizar correos ni contraseñas del personal real.
3. Tras el alta, verificar los ID asignados en `auth.users`.
4. Crear en `public.perfiles` el perfil correspondiente a cada ID con estos roles exactos:
   - Linens: `departamento='Linens', nivel='lider'`.
   - Drivers: `departamento='Drivers', nivel='operador', zona='Norte'`.
   - Cleaning: `departamento='Limpieza', nivel='operador', zona='Norte'`.
   Las claves foráneas exigen que existan los ID de Auth. No introducir IDs inventados.
5. Asignar datos ficticios de checkouts, bolsa y limpieza según el proceso autorizado,
   verificar los permisos en la aplicación con tres sesiones diferentes.
6. Ejecutar los flujos: contenido preparado → escaneo por driver → foto de entrega →
   recepción del cleaner sin faltantes, con faltantes, sobrantes, y sin señal.
7. Comprobar push al líder de Drivers cuando falte confirmación de entrega. **Aún no probado**.
8. No permitir que una incidencia o bolsa ausente bloquee indebidamente el flujo de Cleaning.

## Recomendación de publicación
El frontend se aloja en `opsflow-piloto-pruebas.vercel.app` (Vercel). La base de datos
está en `yxgilbgwuxmlbdrbfisi` (Supabase PRUEBAS). El proyecto `opsflow` de Vercel
se mantiene separado y no se ha cambiado su despliegue desde `main`. Comprobar la
etiqueta PILOTO antes de iniciar sesión y no fusionar a `main`.

## Evidencias
- Pruebas navegador: https://github.com/ivanyesith-spec/opsflow/actions/runs/39771596228
- SQL 37: `supabase/migraciones/37-PEGAR-pruebas_bolsas.sql`
- En esta rama: `tests/ui-bolsas.test.cjs`, `tests/bolsas.test.cjs`

**Criterio de aprobación del piloto:** los tests de navegador con datos simulados
NO sustituyen las pruebas E2E autenticadas con usuarios ficticios conectados al Supabase
de pruebas. No aprobar producción hasta finalizar esas pruebas y las verificaciones de seguridad.
