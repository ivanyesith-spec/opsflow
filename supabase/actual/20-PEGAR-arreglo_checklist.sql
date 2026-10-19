-- OpsFlow · arreglo: la checklist no se abría después de revisar los linens (10 oct 2026)
-- Causa: el archivo 13 se pegó después del 15 y dejó dos funciones en su versión antigua
-- (mi_checklist no decía que los linens ya estaban revisados, y registrar_foto no pedía la revisión).
-- Esto las devuelve a su versión buena. Se puede ejecutar varias veces y no borra datos.

create or replace function public.mi_checklist(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id;
  if not found or public.mi_nivel() is null
     or not (public._lider_limpieza() or (v.asignada_a = (select auth.uid()) and v.publicada)) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return jsonb_build_object(
    'inicio_qr', v.inicio_qr, 'fin_qr', v.fin_qr, 'linens_revisado', v.linens_revisado, 'cierre', v.cierre, 'personas', v.personas, 'estado', v.estado,
    'pasos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'sala', p.sala, 'en', p.texto_en, 'es', p.texto_es,
                          'obligatorio', p.obligatorio, 'hecho', v.checklist ? p.id::text) order by p.orden)
                       from public.checklist_pasos p where p.tipo = v.tipo and p.activo), '[]'::jsonb),
    'fotos', coalesce((select jsonb_object_agg(f.sala, f.ruta) from public.fotos_cierre f where f.limpieza_id = p_id), '{}'::jsonb));
end $$;

create or replace function public.registrar_foto(p_id uuid, p_sala text, p_ruta text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  if p_sala not in ('bedroom', 'bathroom', 'kitchen', 'living', 'basura') then raise exception 'Sala no válida.'; end if;
  if split_part(p_ruta, '/', 1) <> p_id::text then raise exception 'La foto no es de esta limpieza.'; end if;
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por)
  values (p_id, p_sala, p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
end $$;

-- Comprobación: las dos filas deben decir true
select p.proname, (p.prosrc like '%linens_revisado%' or p.prosrc like '%Check the linens%') as arreglada
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('mi_checklist', 'registrar_foto') order by 1;
