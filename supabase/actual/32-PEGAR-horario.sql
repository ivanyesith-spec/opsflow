-- OpsFlow · horario estimado de cada equipo: la hora de entrada solo vale para el PRIMER apartamento (13 oct 2026)
-- Corrección de Ivan a SPEC-rutas-driver. Ejecutar DESPUES de 30-PEGAR-equipos.sql. Se puede ejecutar varias veces.
--   · 1er apartamento del equipo: la hora de entrada (11:00 si nadie la cambió), nunca antes del check-out del huésped.
--   · Los siguientes: fin estimado del anterior + 15 min de traslado (y nunca antes de su check-out).
--   · Duración estimada: la mediana real de ese apartamento y tipo (si hay 3 o más limpiezas con QR en 90 días);
--     si no, la de la tabla duracion_tipo (Operación la puede cambiar).
--   · En cuanto un apartamento empieza o termina de verdad, los siguientes se recalculan con la hora real.
--   · La bolsa de linens de cada apartamento debe llegar antes de la hora (estimada) en que el equipo entra en él.

-- 1. Duración por defecto de cada tipo de limpieza (mientras no hay datos reales) ----------------
create table if not exists public.duracion_tipo (
  tipo    public.tipo_limpieza primary key,
  minutos int not null check (minutos between 10 and 600)
);
alter table public.duracion_tipo enable row level security;
revoke all on public.duracion_tipo from anon;
revoke insert, update, delete, truncate on public.duracion_tipo from authenticated;
drop policy if exists "duracion_tipo: lectura" on public.duracion_tipo;
create policy "duracion_tipo: lectura" on public.duracion_tipo for select to authenticated using (true);
insert into public.duracion_tipo (tipo, minutos) values
  ('normal', 90), ('refresh', 45), ('deep', 180), ('huesped_dentro', 45), ('foto', 60), ('post_mantenimiento', 60)
on conflict (tipo) do nothing;

-- Minutos estimados de una limpieza: la mediana real del apartamento (3+ medidas) o el valor por defecto del tipo
create or replace function public._duracion(p_prop uuid, p_tipo public.tipo_limpieza)
returns int language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select round(percentile_cont(0.5) within group (order by extract(epoch from (l.fin - l.inicio)) / 60))::int
       from public.limpiezas l
      where l.propiedad_id = p_prop and l.tipo = p_tipo and l.estado = 'terminada' and l.inicio_qr and l.fin_qr
        and l.fecha >= (now() at time zone 'Europe/Malta')::date - 90
        and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'
      having count(*) >= 3),
    (select minutos from public.duracion_tipo where tipo = p_tipo), 90)
$$;

-- 2. Horario del día de un equipo (por su responsable) ---------------------------------------------
create or replace function public._horario_equipo(p_fecha date, p_cleaner uuid)
returns table (limpieza_id uuid, inicio timestamptz, fin timestamptz, primera boolean, real_inicio boolean, minutos int)
language plpgsql stable security definer set search_path = ''
as $$
declare r record; t timestamptz; fin_prev timestamptz := null; n int := 0; d int;
begin
  for r in select l.id, l.inicio, l.fin, l.estado, l.tipo, l.propiedad_id, c.hora_salida
             from public.limpiezas l join public.checkouts c on c.id = l.checkout_id
            where l.fecha = p_fecha and l.asignada_a = p_cleaner and l.estado::text <> 'cancelada'
            order by l.orden nulls last, l.creado_en
  loop
    n := n + 1;
    t := case when n = 1 then (p_fecha + public._hora_entrada(p_fecha, p_cleaner)) at time zone 'Europe/Malta'
              else fin_prev + interval '15 minutes' end;
    if r.hora_salida is not null then t := greatest(t, (p_fecha + r.hora_salida) at time zone 'Europe/Malta'); end if;
    d := public._duracion(r.propiedad_id, r.tipo);
    limpieza_id := r.id; primera := n = 1; minutos := d;
    real_inicio := r.inicio is not null;
    inicio := coalesce(r.inicio, t);
    fin := coalesce(r.fin, greatest(inicio + make_interval(mins => d), case when r.estado = 'en_curso' then now() end));
    fin_prev := fin;
    return next;
  end loop;
end $$;
revoke execute on function public._duracion(uuid, public.tipo_limpieza), public._horario_equipo(date, uuid) from public, anon, authenticated;

-- La hora límite de la bolsa = la hora (estimada) en que el equipo entra en ESE apartamento
create or replace function public._limite_bolsa(p_limpieza uuid)
returns timestamptz language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select h.inicio from public.limpiezas l, public._horario_equipo(l.fecha, l.asignada_a) h
      where l.id = p_limpieza and l.asignada_a is not null and h.limpieza_id = l.id),
    (select (l.fecha + time '11:00') at time zone 'Europe/Malta' from public.limpiezas l where l.id = p_limpieza))
$$;
-- ¿Es la hora fija del primer apartamento (true) o una estimación (false)?
create or replace function public._limite_fijo(p_limpieza uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select coalesce((select h.primera and not h.real_inicio from public.limpiezas l, public._horario_equipo(l.fecha, l.asignada_a) h
                    where l.id = p_limpieza and h.limpieza_id = l.id), true)
$$;
revoke execute on function public._limite_bolsa(uuid), public._limite_fijo(uuid) from public, anon, authenticated;

-- 3. Horario del día para los líderes (Asignar, Seguimiento, Drivers) -------------------------------
create or replace function public.horario_dia(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public._lider_limpieza() or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Solo los líderes u Operación.';
  end if;
  return coalesce((select jsonb_object_agg(h.limpieza_id, jsonb_build_object(
      'inicio', to_char(h.inicio at time zone 'Europe/Malta', 'HH24:MI'), 'fin', to_char(h.fin at time zone 'Europe/Malta', 'HH24:MI'),
      'primera', h.primera, 'real', h.real_inicio, 'minutos', h.minutos))
    from (select distinct asignada_a from public.limpiezas where fecha = p_fecha and asignada_a is not null) e,
         public._horario_equipo(p_fecha, e.asignada_a) h), '{}'::jsonb);
end $$;
revoke execute on function public.horario_dia(date) from public, anon;
grant  execute on function public.horario_dia(date) to authenticated;

-- 4. Pantallas ---------------------------------------------------------------------------------------
-- Día del cleaner: + a qué hora empieza cada apartamento (la del 1º es la de entrada; las demás, estimadas)
create or replace function public.mi_dia(p_fecha date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x->>'orden')::int nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', l.id, 'orden', l.orden,
      'con', (select string_agg(split_part(pf.nombre, ' ', 1), ', ' order by pf.nombre) from public.perfiles pf
              where pf.id = any(public._miembros_de(l.id)) and pf.id <> (select auth.uid())),
      'presente', public._presente(l.id),
      'inicio', to_char(public._limite_bolsa(l.id) at time zone 'Europe/Malta', 'HH24:MI'), 'inicio_fijo', public._limite_fijo(l.id), 'tipo', l.tipo, 'estado', l.estado, 'motivo', l.motivo_no_entrar, 'linens_revisado', l.linens_revisado,
      'bolsa', (select jsonb_build_object('estado', b.estado, 'entregada_en', to_char(b.entregada_en at time zone 'Europe/Malta', 'HH24:MI'), 'comentario', b.comentario) from public.bolsas b where b.limpieza_id = l.id),
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'camas_dobles', p.camas_dobles, 'camas_indiv', p.camas_indiv, 'sofas', p.sofas_cama, 'banos', p.banos, 'notas', p.notas,
      'salida', to_char(c.hora_salida, 'HH24:MI'), 'entrada', to_char(c.hora_entrada, 'HH24:MI'),
      'pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle,
                     'cantidad', pe.cantidad, 'estado', pe.estado, 'items', pe.items,
                     'listo_a', to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI'), 'listo_creado', case when pe.listo_a is not null then pe.creado_en end) order by pe.creado_en)
                     from public.pendientes pe where pe.limpieza_id = l.id), '[]'::jsonb)) x
    from public.limpiezas l
    join public.propiedades p on p.id = l.propiedad_id
    join public.checkouts c on c.id = l.checkout_id
    where l.fecha = p_fecha and l.publicada and public._soy_miembro(l.id) and l.estado::text <> 'cancelada'
      and public.mi_nivel() is not null
  ) t
$$;

-- Driver: + si la hora límite de la bolsa es la de entrada (fija) o estimada
create or replace function public.mis_trabajos()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not public._es_driver() then raise exception 'Esta pantalla es para drivers.'; end if;
  return jsonb_build_object(
    'bolsas', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'limpieza_id', b.limpieza_id, 'zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'incidencia', b.incidencia,
        'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end,
        'limite', to_char(public._limite_bolsa(l.id) at time zone 'Europe/Malta', 'HH24:MI'), 'limite_fijo', public._limite_fijo(l.id),
        'lat', case when p.coord_estado = 'confirmada' then p.lat end, 'lng', case when p.coord_estado = 'confirmada' then p.lng end, 'coord', p.coord_estado)
        order by public._limite_bolsa(l.id), (c.fecha = v_hoy and c.hora_entrada is not null) desc, c.hora_entrada, p.codigo)
      from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
      join public.checkouts c on c.id = l.checkout_id
      where b.driver = (select auth.uid()) and b.estado = 'en_camion'), '[]'::jsonb),
    'listas', coalesce((select jsonb_agg(jsonb_build_object('zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'limite', to_char(public._limite_bolsa(l.id) at time zone 'Europe/Malta', 'HH24:MI'))
        order by public._limite_bolsa(l.id), c.hora_entrada nulls last, p.codigo)
      from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
      join public.checkouts c on c.id = l.checkout_id
      where b.fecha = v_hoy and b.estado = 'preparada' and l.estado::text <> 'cancelada'), '[]'::jsonb));
end $$;
