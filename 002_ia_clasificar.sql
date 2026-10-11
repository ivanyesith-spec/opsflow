-- OpsFlow · IA · 002 — Clasificar reportes del campo
-- Se ejecuta UNA vez en Supabase → SQL Editor → pegar todo → Run.
-- Seguro de repetir: no borra nada.
--
-- Que hace: cuando un cleaner manda un reporte "Other", la funcion del
-- servidor `clasificar` le pide a la IA una SUGERENCIA (departamento,
-- urgencia y resumen en espanol). La sugerencia se guarda aqui y el lider
-- la acepta o la corrige. La IA nunca asigna trabajo.

-- 1. Columnas de la sugerencia en cada pendiente ------------------------
alter table public.pendientes
  add column if not exists ia_departamento text,   -- lo que propone la IA
  add column if not exists ia_urgencia     text check (ia_urgencia in ('alta', 'media', 'baja')),
  add column if not exists ia_resumen      text,   -- el reporte en espanol, una linea
  add column if not exists ia_motivo       text,   -- por que lo propone
  add column if not exists ia_en           timestamptz,
  add column if not exists ia_decision     text check (ia_decision in ('aceptada', 'corregida')),
  add column if not exists ia_decision_dep text,   -- lo que decidio el lider
  add column if not exists ia_decidida_por uuid references public.perfiles(id),
  add column if not exists ia_decidida_en  timestamptz;

-- Desde el navegador NO se escriben estas columnas: las escribe el servidor
-- (sugerencia) o la funcion de abajo (decision del lider).
revoke update (ia_departamento, ia_urgencia, ia_resumen, ia_motivo, ia_en,
               ia_decision, ia_decision_dep, ia_decidida_por, ia_decidida_en)
  on public.pendientes from anon, authenticated;

-- 2. Contador de uso (para el tope mensual de gasto) ---------------------
create table if not exists public.ia_uso (
  id           bigint generated always as identity primary key,
  pendiente_id uuid,
  modelo       text not null,
  tokens_in    int  not null default 0,
  tokens_out   int  not null default 0,
  ok           boolean not null default true,
  error        text,
  creado_en    timestamptz not null default now()
);
alter table public.ia_uso enable row level security;
revoke all on public.ia_uso from anon, authenticated;

create policy "ia_uso: solo operacion lee"
on public.ia_uso for select to authenticated
using ((select public.mi_nivel()) = 'operacion');
grant select on public.ia_uso to authenticated;

-- 3. El lider acepta o corrige la sugerencia -----------------------------
create or replace function public.decidir_clasificacion(p_id uuid, p_departamento text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_sug text;
begin
  if (select public.mi_nivel()) not in ('lider', 'operacion') then
    raise exception 'Solo un lider puede decidir el departamento.';
  end if;
  if p_departamento not in ('Limpieza', 'Linens', 'Drivers', 'Bodega', 'Mantenimiento', 'Property manager', 'Reservaciones', 'Operación') then
    raise exception 'Departamento no valido: %', p_departamento;
  end if;
  select ia_departamento into v_sug from public.pendientes where id = p_id;
  if not found then raise exception 'No existe ese pendiente.'; end if;

  update public.pendientes
     set ia_decision     = case when v_sug = p_departamento then 'aceptada' else 'corregida' end,
         ia_decision_dep = p_departamento,
         ia_decidida_por = (select auth.uid()),
         ia_decidida_en  = now()
   where id = p_id;
end $$;

revoke execute on function public.decidir_clasificacion(uuid, text) from public, anon;
grant  execute on function public.decidir_clasificacion(uuid, text) to authenticated;

-- 4. Cuanto acierta la IA (para decidir si vale la pena) -----------------
--    select * from public.ia_aciertos;
create or replace view public.ia_aciertos with (security_invoker = true) as
select date_trunc('week', ia_en)::date                          as semana,
       count(*) filter (where ia_en is not null)                as sugeridas,
       count(*) filter (where ia_decision = 'aceptada')         as aceptadas,
       count(*) filter (where ia_decision = 'corregida')        as corregidas,
       round(100.0 * count(*) filter (where ia_decision = 'aceptada')
             / nullif(count(*) filter (where ia_decision is not null), 0), 0) as pct_acierto
  from public.pendientes
 where ia_en is not null
 group by 1 order by 1 desc;
