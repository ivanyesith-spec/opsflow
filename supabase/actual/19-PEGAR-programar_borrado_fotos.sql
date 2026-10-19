-- OpsFlow · tarea nocturna: borrar las fotos de más de 30 días
-- Ejecutar DESPUES de desplegar la función borrar-fotos. Se puede ejecutar varias veces.
-- Cada noche a las 02:15 UTC (03:15 / 04:15 en Malta) llama a la función.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- Si ya existía, se reemplaza
select cron.unschedule(jobid) from cron.job where jobname = 'opsflow-borrar-fotos';

select cron.schedule(
  'opsflow-borrar-fotos',
  '15 2 * * *',
  $$ select net.http_post(
       url     := 'https://zxsiantglodsqqvigndk.supabase.co/functions/v1/borrar-fotos',
       headers := '{"Content-Type": "application/json"}'::jsonb,
       body    := '{}'::jsonb) $$
);

-- Comprobación: debe salir una fila "opsflow-borrar-fotos" con "15 2 * * *"
select jobname, schedule, active from cron.job where jobname = 'opsflow-borrar-fotos';
