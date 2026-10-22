# OpsFlow — Etapa 2: bolsas con contenido y recepción

**Rama:** `piloto-norte-3dep` · **Estado:** SQL validado en proyecto de pruebas, UI simulada validada, **SIN DESPLEGAR**.

## Qué hace

Se reutilizan las tablas y procesos existentes: cada limpieza tiene una bolsa con QR.
La bolsa registra ahora el contenido real, cantidades recibidas, diferencias y un historial
de preparación → recogida → entrega → recepción.

**La demanda se calcula a partir de checkouts reales del día**. No se inventan
kits ni cantidades por temporada. El líder de Linens introduce o corrige cantidades
antes de la recogida y el sistema muestra las cantidades agregadas confirmadas.
La demanda total *no equivale a inventario disponible*.

Linens confirma los artículos; el driver escanea y adquiere custodia, pero
no certifica el contenido; el cleaner asignado confirma lo recibido.
Si el conductor olvidó marcar «entregada», puede recibirse una bolsa ya escaneada,
pero el sistema deja constancia «sin confirmación del driver». Si el cleaner
marca faltantes, se crea un único pendiente ligado a esa bolsa. Los sobrantes
se registran sin generar automáticamente otro pendiente. La solicitud manual
independiente de «linen needed» sigue existiendo.

## Archivos

- `36-PEGAR-contenido_recepcion_bolsas.sql`: cambios del backend, control de roles, estados,
  contenido, recepción e idempotencia, historial y resumen diario.
- `37-PEGAR-pruebas_bolsas.sql`: 22 verificaciones SQL, con rollback de los datos temporales.
- `../../index.html`: pantallas de contenido Linens, recepción Cleaning y tablero.
- `../../tests/bolsas.test.cjs`: pruebas locales de código y contrato.
- `../../tests/ui-bolsas.test.cjs`: siete pruebas de interacción reales con Chromium y Supabase simulado, sin llamadas a producción.
- `../../.github/workflows/opsflow-local-tests.yml`: ejecuta las pruebas de etapas 1 y 2 y las pruebas de Chromium en GitHub.

## Validación realizada — 22 de octubre de 2026

- Supabase de pruebas: proyecto `yxgilbgwuxmlbdrbfisi`, con marca `opsflow_entorno.tipo='pruebas'`; ninguna propiedad real.
- Migración 36 instalada como `stage2_bags_contents_receipts_20261022`.
- Prueba SQL 37: **22 de 22 casos OK**, incluidos permisos, diferencias, idempotencia y rollback.
- Tras la prueba no permanecieron las cuentas ni apartamentos temporales.
- GitHub Actions ejecutó las pruebas de código anteriores más **7 pruebas E2E con Chromium (7/7 OK)**.
  Estas pruebas usan un cliente Supabase simulado y bloquean todo el tráfico externo.
- Resultado de GitHub Actions: https://github.com/ivanyesith-spec/opsflow/actions/runs/39767195647

## Pendiente antes del piloto

1. La interfaz **aún tiene por defecto la URL de Supabase de producción** en `index.html`.
   No se debe abrir esa URL como si fuera una validación de pruebas.
   Hace falta seleccionar y verificar explícitamente la configuración del proyecto de pruebas
   antes de autenticarse con cuentas piloto.
2. Crear o disponer de usuarios **ficticios** de los tres departamentos en el entorno de pruebas
   y verificar el flujo completo desde dispositivos reales (incluidas fotos, QR físicos
   y reconexión sin señal).
3. Revisar las advertencias de Supabase sobre funciones `SECURITY DEFINER` y permisos de ejecución.
4. Comprobar la entrega de avisos al líder de Drivers cuando el cleaner recibe una bolsa
   sin confirmación de entrega; el evento existe, pero no está validada la notificación push.
5. Separar la validación de recepción de una ausencia de bolsa: el checklist no debe
   quedar bloqueado indefinidamente sin un procedimiento operativo autorizado.
6. No fusionar `piloto-norte-3dep` en `main`, ni ejecutar SQL ni despliegues en producción
   sin autorización expresa del responsable.

## Atención

Las pruebas en GitHub combinan verificaciones estáticas y siete flujos de navegador,
pero con datos simulados. No sustituyen las pruebas operativas con usuarios reales.
Las bolsas existentes sin contenido registrado requieren revisión operativa antes
de usar el nuevo flujo de recepción; no debe atribuirse una recepción ficticia.
