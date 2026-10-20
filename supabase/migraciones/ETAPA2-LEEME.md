# OpsFlow — Etapa 2: bolsas con contenido y recepción

**Rama:** `piloto-norte-3dep` · **Estado:** implementado en GitHub, **SIN DESPLEGAR**.

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
- `../../.github/workflows/opsflow-local-tests.yml`: ejecuta pruebas de etapas 1 y 2 en GitHub.

## Validación segura (pendiente de ejecución real en Supabase)

1. Abrir exclusivamente el proyecto **Supabase de PRUEBAS**. Verificar URL y PROJECT ID.
2. Confirmar que existen y están aplicados `00-MONTAR`, migraciones 34 y pruebas 35;
   no volver a montar el backend si ya existe.
3. Copiar el SQL 36, sustituir **solo** `ESCRIBE-AQUI-EL-ID-DEL-PROYECTO` por el ID de pruebas y ejecutar en SQL Editor.
   El script aborta si falta la marca `opsflow_entorno` que identifica el entorno de pruebas.
4. Copiar SQL 37, utilizar el mismo ID, ejecutar y guardar **todas las filas de resultados**.
   Deben mostrarse las comprobaciones 1–22 como OK, sin comprobación 0 de error inesperado.
5. Ejecutar pruebas funcionales en navegador con usuarios de cada departamento, incluidos
   sustitutos, recogida con QR, entrega sin marcar, faltantes, sobrantes y reintento offline.
6. No ejecutar ningún SQL ni despliegue en producción sin autorización expresa del dueño.
   No fusionar la rama a `main` hasta completar y revisar las pruebas reales.

## Atención

Las pruebas automáticas de GitHub son **locales y estáticas**. No sustituyen a
las pruebas SQL 37 en Supabase ni a la validación de interfaz en navegador.
Las bolsas existentes sin contenido registrado requieren revisión operativa antes
de usar el nuevo flujo de recepción; no debe atribuirse una recepción ficticia.
