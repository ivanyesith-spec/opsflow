-- 3. Asignaciones de Limpieza: solo Cleaning Leader -----------------------------------------
--    (mismo cuerpo que 30-PEGAR-equipos.sql / 04 / 27; solo cambia quién puede)
create or replace function public.asignar_limpieza(p_id uuid, p_cleaner uuid, p_orden int, p_tipo public.tipo_limpieza)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_resp uuid;
begin
  if not public._asigna('Limpieza') then raise exception 'Solo el líder de limpieza (o su sustituto) asigna limpiezas.'; end if;
  select * into v from public.limpiezas where id = p_id for update;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if v.estado not in ('sin_asignar', 'asignada') then raise exception 'Esa limpieza ya empezó: no se puede reasignar.'; end if;
  if p_cleaner is not null and not exists (
       select 1 from public.perfiles where id = p_cleaner and activo and departamento = 'Limpieza' and nivel = 'operador') then
    raise exception 'Solo se puede asignar a un cleaner activo.';
  end if;
  v_resp := case when p_cleaner is null then null else public._responsable(p_cleaner) end;
  update public.limpiezas
     set asignada_a = v_resp, orden = p_orden, tipo = coalesce(p_tipo, tipo),
         estado = case when v_resp is null then 'sin_asignar' else 'asignada' end::public.estado_limpieza,
         publicada = case when v_resp is null then false else publicada end
   where id = p_id;
  perform public._rehacer_miembros(p_id);
  perform public._evento('asignada' || coalesce(' a ' || public._equipo_txt(v_resp), ''), p_id, null);
end $$;

create or replace function public.publicar_orden(p_fecha date)
returns int language plpgsql security definer set search_path = ''
as $$
declare n int;
begin
  if not public._asigna('Limpieza') then raise exception 'Solo el líder de limpieza (o su sustituto) publica el orden.'; end if;
  update public.limpiezas set publicada = true
   where fecha = p_fecha and asignada_a is not null and not publicada;
  get diagnostics n = row_count;
  insert into public.eventos (quien, que) values ((select auth.uid()), 'orden publicado ' || p_fecha || ' (' || n || ')');
  return n;
end $$;

create or replace function public.guardar_equipo(p_miembros uuid[])
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_viejos uuid[]; e record;
begin
  if not public._asigna('Limpieza') then raise exception 'Solo el líder de limpieza (o su sustituto) forma equipos.'; end if;
  p_miembros := array(select distinct x from unnest(p_miembros) x where x is not null);
  if cardinality(p_miembros) not between 2 and 3 then raise exception 'Un equipo es de 2 o 3 cleaners.'; end if;
  if exists (select 1 from unnest(p_miembros) x where not exists (
       select 1 from public.perfiles where id = x and activo and departamento = 'Limpieza' and nivel = 'operador')) then
    raise exception 'Solo cleaners activos.';
  end if;
  -- Sacar a estas personas de sus equipos anteriores (un equipo que se queda con 1 persona se deshace)
  v_viejos := array(select distinct m.equipo_id from public.equipo_miembros m where m.perfil_id = any(p_miembros) and m.hasta is null);
  update public.equipo_miembros set hasta = now() where perfil_id = any(p_miembros) and hasta is null;
  for e in select x as id from unnest(v_viejos) x loop
    if (select count(*) from public.equipo_miembros where equipo_id = e.id and hasta is null) < 2 then
      update public.equipo_miembros set hasta = now() where equipo_id = e.id and hasta is null;
      update public.equipos set activo = false, deshecho_en = now() where id = e.id;
    elsif not exists (select 1 from public.equipo_miembros m join public.equipos q on q.id = m.equipo_id
                      where m.equipo_id = e.id and m.perfil_id = q.responsable and m.hasta is null) then
      update public.equipos set responsable = (select perfil_id from public.equipo_miembros where equipo_id = e.id and hasta is null limit 1) where id = e.id;
    end if;
  end loop;
  insert into public.equipos (responsable, creado_por) values (p_miembros[1], (select auth.uid())) returning id into v_id;
  insert into public.equipo_miembros (equipo_id, perfil_id) select v_id, x from unnest(p_miembros) x;
  perform public._reajustar(p_miembros || coalesce((select array_agg(m.perfil_id) from public.equipo_miembros m where m.equipo_id = any(v_viejos)), '{}'));
  insert into public.eventos (quien, que) values ((select auth.uid()), 'equipo formado: ' || public._equipo_txt(p_miembros[1]));
  return v_id;
end $$;

create or replace function public.deshacer_equipo(p_equipo uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_nom text; v_m uuid[];
begin
  if not public._asigna('Limpieza') then raise exception 'Solo el líder de limpieza (o su sustituto) deshace equipos.'; end if;
  select public._equipo_txt(responsable) into v_nom from public.equipos where id = p_equipo and activo;
  if v_nom is null then raise exception 'Ese equipo no existe o ya se deshizo.'; end if;
  v_m := array(select perfil_id from public.equipo_miembros where equipo_id = p_equipo and hasta is null);
  update public.equipo_miembros set hasta = now() where equipo_id = p_equipo and hasta is null;
  update public.equipos set activo = false, deshecho_en = now() where id = p_equipo;
  perform public._reajustar(v_m);
  insert into public.eventos (quien, que) values ((select auth.uid()), 'equipo deshecho: ' || v_nom);
end $$;

create or replace function public.fijar_entrada(p_fecha date, p_cleaner uuid, p_hora time)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public._asigna('Limpieza') then raise exception 'Solo el líder de limpieza (o su sustituto) fija la hora de entrada.'; end if;
  if p_hora is null or p_hora < time '05:00' or p_hora > time '20:00' then raise exception 'La hora tiene que estar entre las 05:00 y las 20:00.'; end if;
  if p_fecha < (now() at time zone 'Europe/Malta')::date then raise exception 'No se cambia la hora de un día que ya pasó.'; end if;
  if not exists (select 1 from public.perfiles where id = p_cleaner and departamento = 'Limpieza' and nivel = 'operador') then
    raise exception 'Ese equipo no existe.';
  end if;
  insert into public.entradas_equipo (fecha, cleaner, hora, fijada_por) values (p_fecha, p_cleaner, p_hora, (select auth.uid()))
  on conflict (fecha, cleaner) do update set hora = excluded.hora, fijada_por = excluded.fijada_por, fijada_en = now();
  insert into public.eventos (quien, que) values ((select auth.uid()),
    'hora de entrada ' || to_char(p_hora, 'HH24:MI') || ' · ' || (select nombre from public.perfiles where id = p_cleaner) || ' · ' || to_char(p_fecha, 'DD/MM'));
end $$;

-- 4. Asignaciones de Drivers: solo Drivers Leader (mismo cuerpo que 21-PEGAR-tablero_bolsas.sql) --
create or replace function public.asignar_tarea(p_id uuid, p_driver uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  if not public._asigna('Drivers') then raise exception 'Solo el líder de drivers (o su sustituto) asigna.'; end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or not public._en_driver(v) then raise exception 'Ese pendiente no está esperando a un driver.'; end if;
  if not exists (select 1 from public.perfiles where id = p_driver and activo and departamento = 'Drivers' and nivel = 'operador') then
    raise exception 'Solo se asigna a un driver activo.';
  end if;
  update public.pendientes set tomado_por = p_driver, tomado_en = now(), asignado_por = (select auth.uid()) where id = p_id;
  perform public._evento('asignada a driver por el líder', v.limpieza_id, p_id);
end $$;

