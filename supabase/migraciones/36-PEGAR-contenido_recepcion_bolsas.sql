-- OpsFlow · 36 · Etapa 2: contenido, custodia y recepción de bolsas
-- Basado en los scripts 1–34. SOLO proyecto Supabase de PRUEBAS, jamás producción.
-- No se fija un kit estacional: la demanda nace de los checkouts y las cantidades
-- son introducidas por Linens en cada bolsa.
select set_config('opsflow.proyecto', 'ESCRIBE-AQUI-EL-ID-DEL-PROYECTO', false);

begin;

-- Freno de seguridad: el identificador escrito tiene que coincidir con la marca "pruebas" que dejó 00-MONTAR.
-- Producción no tiene esa marca → se para sin cambiar nada.
do $$
declare v text := current_setting('opsflow.proyecto', true); v_tipo text; v_proy text;
begin
  if v is null or v !~ '^[a-z]{20}$' then
    raise exception 'PARADO: escribe en la primera línea el identificador del proyecto de pruebas (20 letras minúsculas). No se ha cambiado nada.';
  end if;
  if v = 'zxsiantglodsqqvigndk' then
    raise exception 'PARADO: ese identificador es el de PRODUCCIÓN. No se ha cambiado nada.';
  end if;
  if to_regclass('public.opsflow_entorno') is not null then
    execute 'select tipo, proyecto from public.opsflow_entorno where id = 1' into v_tipo, v_proy;
  end if;
  if v_tipo is distinct from 'pruebas' then
    raise exception 'PARADO: esta base de datos no tiene la marca de entorno de PRUEBAS (la crea 00-MONTAR). No se ha cambiado nada.';
  end if;
  if v_proy <> v then
    raise exception 'PARADO: escribiste % pero este proyecto está marcado como %. No se ha cambiado nada.', v, v_proy;
  end if;
  if exists (select 1 from public.propiedades where not es_prueba) then
    raise exception 'PARADO: hay propiedades reales en esta base de datos. No se ha cambiado nada.';
  end if;
end $$;


-- A. Ampliar la bolsa existente; no crear una segunda tabla de bolsas
alter table public.bolsas add column if not exists contenido jsonb not null default '{}'::jsonb;
alter table public.bolsas add column if not exists recibido jsonb not null default '{}'::jsonb;
alter table public.bolsas add column if not exists diferencia jsonb not null default '{}'::jsonb;
alter table public.bolsas add column if not exists historial jsonb not null default '[]'::jsonb;
alter table public.bolsas add column if not exists recibida_por uuid references public.perfiles(id);
alter table public.bolsas add column if not exists recibida_en timestamptz;
alter table public.bolsas add column if not exists entrega_sin_confirmar boolean not null default false;
alter table public.bolsas add column if not exists recepcion_idempotencia uuid;
create unique index if not exists bolsas_recepcion_idempotencia on public.bolsas(recepcion_idempotencia)
  where recepcion_idempotencia is not null;
alter table public.bolsas drop constraint if exists bolsas_estado_check;
alter table public.bolsas add constraint bolsas_estado_check
  check (estado in ('por_preparar','preparada','en_camion','entregada','recibida'));
-- Vincular únicamente los faltantes nacidos de la recepción (los linen needed manuales siguen independientes)
alter table public.pendientes add column if not exists bolsa_id uuid references public.bolsas(id);
create unique index if not exists pendientes_un_faltante_por_bolsa
  on public.pendientes (bolsa_id) where bolsa_id is not null and tipo::text = 'linens';

-- B. Validación en servidor de los 11 artículos del catálogo, cantidades enteras 0..50
create or replace function public._bolsa_validar_contenido(p_items jsonb, p_exige_articulos boolean default false)
returns void language plpgsql security definer set search_path = ''
as $$
declare v record; n int := 0;
begin
  if jsonb_typeof(p_items) is distinct from 'object' then
    raise exception using errcode='22023', message='El contenido debe ser un objeto de cantidades.';
  end if;
  for v in select key, value from jsonb_each(p_items) loop
    if public._linens_nombre(v.key) is null or jsonb_typeof(v.value) is distinct from 'number'
       or v.value::text !~ '^(0|[1-9][0-9]?)$' then
      raise exception using errcode='22023', message='Artículo o cantidad de bolsa inválidos.';
    end if;
    if (v.value::text)::int > 50 then
      raise exception using errcode='22023', message='La cantidad por artículo no puede superar 50.';
    end if;
    n := n + (v.value::text)::int;
  end loop;
  if p_exige_articulos and n = 0 then
    raise exception using errcode='22023', message='Añade al menos un artículo a la bolsa.';
  end if;
end $$;
revoke execute on function public._bolsa_validar_contenido(jsonb,boolean) from public,anon,authenticated;

-- C. Linens registra contenido real; Operación SOLO consulta; nunca editar después del escaneo
create or replace function public.guardar_contenido_bolsa(p_bolsa uuid, p_contenido jsonb, p_lista boolean default true)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas; v_estado text;
begin
  if not public._es_lider('Linens') then
    raise exception using errcode='42501', message='Solo el líder de Linens o su sustituto prepara bolsas.';
  end if;
  select * into v from public.bolsas where id = p_bolsa for update;
  if not found then raise exception using errcode='22023', message='Esa bolsa no existe.'; end if;
  if v.estado not in ('por_preparar','preparada') then
    raise exception using errcode='22023', message='Bolsa recogida: su contenido ya está bloqueado.';
  end if;
  if exists (select 1 from public.limpiezas where id = v.limpieza_id and estado::text = 'cancelada') then
    raise exception using errcode='22023', message='Esa limpieza está cancelada.';
  end if;
  perform public._bolsa_validar_contenido(p_contenido, coalesce(p_lista,true));
  v_estado := case when coalesce(p_lista,true) then 'preparada' else 'por_preparar' end;
  update public.bolsas set contenido = p_contenido, estado = v_estado,
      preparada_por = case when p_lista then (select auth.uid()) else null end,
      preparada_en = case when p_lista then now() else null end,
      historial = coalesce(historial,'[]'::jsonb) || jsonb_build_array(jsonb_build_object(
        'tipo', case when v.estado = 'preparada' then 'contenido_corregido' else 'preparada' end,
        'por', (select auth.uid()), 'en', now(), 'contenido', p_contenido, 'estado', v_estado))
  where id = p_bolsa;
  perform public._evento('bolsa: contenido confirmado por Linens',v.limpieza_id,null);
  return jsonb_build_object('id',p_bolsa,'estado',v_estado,'contenido',p_contenido);
end $$;
revoke execute on function public.guardar_contenido_bolsa(uuid,jsonb,boolean) from public,anon;
grant execute on function public.guardar_contenido_bolsa(uuid,jsonb,boolean) to authenticated;

-- Impedir que el botón antiguo marque preparada una bolsa sin contenido, o que Operación lo eluda
create or replace function public.preparar_bolsa(p_bolsa uuid, p_lista boolean default true)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas;
begin
  select * into v from public.bolsas where id = p_bolsa;
  if not found then raise exception using errcode='22023', message='Esa bolsa no existe.'; end if;
  perform public.guardar_contenido_bolsa(p_bolsa,v.contenido,p_lista);
end $$;
revoke execute on function public.preparar_bolsa(uuid,boolean) from public,anon;
grant execute on function public.preparar_bolsa(uuid,boolean) to authenticated;

-- D. Custodia: reaprovechar las funciones existentes, agregando historial
create or replace function public.escanear_bolsa(p_qr text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas; v_quien text; v_cod text;
begin
  if not (public.mi_departamento() = 'Drivers' and public.mi_nivel() = 'operador') then raise exception 'Only drivers scan bags.'; end if;
  select * into v from public.bolsas where token = regexp_replace(btrim(coalesce(p_qr, '')), '^OPSFLOW-BAG:', '') for update;
  if not found then raise exception 'This is not an OpsFlow bag label.'; end if;
  select codigo into v_cod from public.propiedades where id = v.propiedad_id;
  if exists (select 1 from public.limpiezas where id = v.limpieza_id and estado::text = 'cancelada') then raise exception 'Cleaning cancelled: leave the bag % at linens.', v_cod; end if;
  if v.estado = 'por_preparar' then raise exception 'Bag % is not ready yet (linens has not marked it).', v_cod; end if;
  if v.estado in ('entregada', 'recibida') then raise exception 'Bag % was already delivered.', v_cod; end if;
  if v.estado = 'en_camion' and v.driver <> (select auth.uid()) then
    select nombre into v_quien from public.perfiles where id = v.driver;
    raise exception 'Bag % is already with %.', v_cod, v_quien;
  end if;
  update public.bolsas set estado = 'en_camion', driver = (select auth.uid()), recogida_en = coalesce(recogida_en, now()),
    historial = coalesce(historial, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('tipo','recogida','por',(select auth.uid()),'en',now())) where id = v.id;
  perform public._evento('bolsa recogida en linens', v.limpieza_id, null);
  return jsonb_build_object('id', v.id, 'codigo', v_cod);
end $$;

create or replace function public.entregar_bolsa(p_bolsa uuid, p_ruta text, p_comentario text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas;
begin
  select * into v from public.bolsas where id = p_bolsa for update;
  if not found or v.driver is distinct from (select auth.uid()) or v.estado <> 'en_camion' then
    raise exception 'This bag is not on your list.';
  end if;
  if p_ruta is distinct from v.limpieza_id || '/bolsa.jpg' then raise exception 'Take the delivery photo first.'; end if;
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por) values (v.limpieza_id, 'bolsa', p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
  update public.bolsas set estado = 'entregada', entregada_en = now(), comentario = nullif(left(btrim(coalesce(p_comentario, '')), 300), ''),
         incidencia = null, incidencia_en = null,
    historial = coalesce(historial, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('tipo','entregada','por',(select auth.uid()),'en',now(),'foto',p_ruta,'comentario',left(coalesce(p_comentario,''),300))) where id = p_bolsa;
  perform public._evento('bolsa entregada' || coalesce(': ' || nullif(btrim(coalesce(p_comentario, '')), ''), ''), v.limpieza_id, null);
end $$;

create or replace function public.no_pude_entregar_bolsa(p_bolsa uuid, p_motivo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas;
begin
  select * into v from public.bolsas where id = p_bolsa for update;
  if not found or v.driver is distinct from (select auth.uid()) or v.estado <> 'en_camion' then raise exception 'This bag is not on your list.'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Write the reason.'; end if;
  update public.bolsas set incidencia = left(btrim(p_motivo), 200), incidencia_en = now(),
    historial = coalesce(historial, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('tipo','incidencia_entrega','por',(select auth.uid()),'en',now(),'motivo',left(btrim(p_motivo),200))) where id = p_bolsa;
  perform public._evento('bolsa no entregada: ' || left(btrim(p_motivo), 200), v.limpieza_id, null);
end $$;

-- E. El cleaner de la limpieza publicada es el único que puede recibir, tras recogida
-- El cliente debe reutilizar el mismo UUID en sus reintentos. El bloqueo FOR UPDATE hace la
-- recepción atómica: una segunda llamada devuelve la primera sin crear otro pendiente.
create or replace function public.recibir_bolsa(p_bolsa uuid, p_faltantes jsonb, p_sobrantes jsonb, p_idempotencia uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas; l public.limpiezas; x record; q int; falt int; sobr int;
        nuevo jsonb := '{}'::jsonb; diff jsonb := '{}'::jsonb;
        items jsonb; cantidad_total int; descripcion text; pedido uuid;
        sin_entrega boolean;
begin
  if public.mi_departamento() is distinct from 'Limpieza'
     or public.mi_nivel() is distinct from 'operador' then
    raise exception using errcode='42501', message='Solo un cleaner asignado recibe la bolsa.';
  end if;
  select * into v from public.bolsas where id = p_bolsa for update;
  if not found then raise exception using errcode='22023', message='Esa bolsa no existe.'; end if;
  select * into l from public.limpiezas where id = v.limpieza_id;
  if not public._soy_miembro(l.id) or not l.publicada then
    raise exception using errcode='42501', message='Esta bolsa no corresponde a tu limpieza.';
  end if;
  if v.estado = 'recibida' then
    select id into pedido from public.pendientes where bolsa_id = v.id and tipo::text='linens';
    return jsonb_build_object('id',v.id,'estado','recibida','ya_registrada',true,'pendiente_id',pedido,
      'contenido',v.contenido,'recibido',v.recibido,'diferencia',v.diferencia);
  end if;
  if l.estado::text <> 'en_curso' then
    raise exception using errcode='22023', message='Primero hay que empezar la limpieza.';
  end if;
  if v.estado not in ('en_camion','entregada') then
    raise exception using errcode='22023', message='La bolsa todavía no consta como recogida por el driver.';
  end if;
  if p_idempotencia is null then
    raise exception using errcode='22023', message='Falta el identificador único de la recepción.';
  end if;
  perform public._bolsa_validar_contenido(v.contenido,true);
  perform public._bolsa_validar_contenido(p_faltantes,false);
  perform public._bolsa_validar_contenido(p_sobrantes,false);
  for x in select key,value from jsonb_each(p_faltantes) loop
    if not v.contenido ? x.key then
      raise exception using errcode='22023', message='No puedes marcar faltante de un artículo no preparado.';
    end if;
    if (x.value::text)::int > (v.contenido->>x.key)::int then
      raise exception using errcode='22023', message='El faltante supera la cantidad preparada.';
    end if;
    if (x.value::text)::int > 0 and coalesce((p_sobrantes->>x.key)::int,0) > 0 then
      raise exception using errcode='22023', message='Un artículo no puede faltar y sobrar a la vez.';
    end if;
  end loop;
  for x in select key,value from jsonb_each(v.contenido) loop
    q := (x.value::text)::int;
    falt := coalesce((p_faltantes->>x.key)::int,0);
    sobr := coalesce((p_sobrantes->>x.key)::int,0);
    nuevo := nuevo || jsonb_build_object(x.key,q-falt+sobr);
    if sobr <> falt then diff := diff || jsonb_build_object(x.key,sobr-falt); end if;
  end loop;
  for x in select key,value from jsonb_each(p_sobrantes) loop
    if not v.contenido ? x.key and (x.value::text)::int > 0 then
      nuevo := nuevo || jsonb_build_object(x.key,(x.value::text)::int);
      diff := diff || jsonb_build_object(x.key,(x.value::text)::int);
    end if;
  end loop;
  sin_entrega := v.estado = 'en_camion';
  select jsonb_agg(jsonb_build_object('item',key,'cantidad',(value::text)::int)),
         sum((value::text)::int),
         string_agg((value::text)||' × '||public._linens_nombre(key),' · ')
    into items,cantidad_total,descripcion
    from jsonb_each(p_faltantes) where (value::text)::int > 0;
  if coalesce(cantidad_total,0) > 0 then
    insert into public.pendientes
      (limpieza_id,propiedad_id,zona,fecha,tipo,detalle,cantidad,prioritario,creado_por,es_prueba,items,bolsa_id)
    values (l.id,l.propiedad_id,l.zona,l.fecha,'linens',left(descripcion,200),
      least(cantidad_total,50),
      exists(select 1 from public.checkouts c where c.id=l.checkout_id and c.hora_entrada is not null),
      (select auth.uid()),l.es_prueba,items,v.id)
    returning id into pedido;
  end if;
  update public.bolsas set estado='recibida',recibida_por=(select auth.uid()),recibida_en=now(),
      recibido=nuevo,diferencia=diff,entrega_sin_confirmar=sin_entrega,
      recepcion_idempotencia=p_idempotencia,
      historial=coalesce(historial,'[]'::jsonb) || jsonb_build_array(jsonb_build_object(
        'tipo','recibida','por',(select auth.uid()),'en',now(),
        'recibido',nuevo,'diferencia',diff,'sin_confirmacion_driver',sin_entrega,'pendiente_id',pedido))
    where id=v.id;
  update public.limpiezas set linens_revisado=coalesce(linens_revisado,now()) where id=l.id;
  perform public._evento(case when sin_entrega then 'bolsa recibida: DRIVER NO CONFIRMÓ ENTREGA'
    else 'bolsa recibida por cleaner' end,l.id,pedido);
  return jsonb_build_object('id',v.id,'estado','recibida','ya_registrada',false,
    'pendiente_id',pedido,'contenido',v.contenido,'recibido',nuevo,'diferencia',diff,
    'entrega_sin_confirmar',sin_entrega);
end $$;
revoke execute on function public.recibir_bolsa(uuid,jsonb,jsonb,uuid) from public,anon;
grant execute on function public.recibir_bolsa(uuid,jsonb,jsonb,uuid) to authenticated;

-- F. Consulta propia del cleaner; no abre datos de otras limpiezas.
create or replace function public.bolsa_mia(p_limpieza uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_departamento() is distinct from 'Limpieza' or public.mi_nivel() is distinct from 'operador'
     or not public._soy_miembro(p_limpieza)
     or not exists(select 1 from public.limpiezas where id=p_limpieza and publicada) then
    raise exception using errcode='42501', message='Esta bolsa no corresponde a tu limpieza.';
  end if;
  return (select jsonb_build_object('id',b.id,'estado',b.estado,'contenido',b.contenido,
      'recibido',b.recibido,'diferencia',b.diferencia,'recibida_en',b.recibida_en,
      'entrega_sin_confirmar',b.entrega_sin_confirmar)
    from public.bolsas b where b.limpieza_id=p_limpieza);
end $$;
revoke execute on function public.bolsa_mia(uuid) from public,anon;
grant execute on function public.bolsa_mia(uuid) to authenticated;

-- G. Tablero: número de checkouts impulsa la demanda total, nunca se inventan kits por temporada.
create or replace function public.resumen_linens_dia(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.mi_nivel() = 'operacion' or public._es_lider('Linens')) then
    raise exception using errcode='42501', message='Solo el líder de Linens o Operación consulta la demanda.';
  end if;
  return jsonb_build_object(
    'checkouts',(select count(*) from public.limpiezas l where l.fecha=p_fecha and l.estado::text<>'cancelada'),
    'sin_preparar',(select count(*) from public.bolsas b join public.limpiezas l on l.id=b.limpieza_id
      where b.fecha=p_fecha and l.estado::text<>'cancelada' and b.estado='por_preparar'),
    'preparadas',(select count(*) from public.bolsas b join public.limpiezas l on l.id=b.limpieza_id
      where b.fecha=p_fecha and l.estado::text<>'cancelada' and b.estado='preparada'),
    'en_camion',(select count(*) from public.bolsas b where b.fecha=p_fecha and b.estado='en_camion'),
    'entregadas',(select count(*) from public.bolsas b where b.fecha=p_fecha and b.estado='entregada'),
    'recibidas',(select count(*) from public.bolsas b where b.fecha=p_fecha and b.estado='recibida'),
    'diferencias',(select count(*) from public.bolsas b where b.fecha=p_fecha and b.estado='recibida' and b.diferencia <> '{}'::jsonb),
    'sin_confirmacion_driver',(select count(*) from public.bolsas b where b.fecha=p_fecha and b.entrega_sin_confirmar),
    'cantidades_confirmadas',(select coalesce(jsonb_object_agg(x.key,x.total),'{}'::jsonb)
      from (select j.key,sum((j.value::text)::int) as total from public.bolsas b
         join public.limpiezas l on l.id=b.limpieza_id cross join lateral jsonb_each(b.contenido) j
         where b.fecha=p_fecha and l.estado::text<>'cancelada' and b.estado<>'por_preparar'
         group by j.key) x)
  );
end $$;
revoke execute on function public.resumen_linens_dia(date) from public,anon;
grant execute on function public.resumen_linens_dia(date) to authenticated;

-- H. Historial de la bolsa: solo líderes de los tres departamentos, sustitutos y Operación.
create or replace function public.historial_bolsa(p_bolsa uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.mi_nivel()='operacion' or public._es_lider('Linens')
    or public._es_lider('Drivers') or public._es_lider('Limpieza')) then
    raise exception using errcode='42501', message='No tienes permiso para consultar este historial.';
  end if;
  return (select coalesce(historial,'[]'::jsonb) from public.bolsas where id=p_bolsa);
end $$;
revoke execute on function public.historial_bolsa(uuid) from public,anon;
grant execute on function public.historial_bolsa(uuid) to authenticated;

-- I. Vista ampliada de bolsas del día (reutiliza la función de 34)
create or replace function public.bolsas_dia(p_fecha date)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if not (public.mi_nivel() = 'operacion' or (public._es_lider_en(array['Linens', 'Drivers', 'Limpieza']))) then
    raise exception 'Solo linens, los líderes u Operación.';
  end if;
  insert into public.bolsas (limpieza_id, propiedad_id, zona, fecha, es_prueba)
  select l.id, l.propiedad_id, l.zona, l.fecha, l.es_prueba from public.limpiezas l
  where l.fecha = p_fecha and l.estado::text <> 'cancelada'
  on conflict (limpieza_id) do nothing;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', b.id, 'estado', b.estado, 'zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
      'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'salida', to_char(c.hora_salida, 'HH24:MI'),
      'cancelada', l.estado::text = 'cancelada', 'driver', d.nombre, 'recogida_en', b.recogida_en, 'entregada_en', b.entregada_en,
      'comentario', b.comentario, 'incidencia', b.incidencia,
      'contenido', b.contenido, 'recibido', b.recibido, 'diferencia', b.diferencia,
      'recibida_por', rp.nombre, 'recibida_en', b.recibida_en, 'entrega_sin_confirmar', b.entrega_sin_confirmar,
      'camas_dobles', p.camas_dobles, 'camas_indiv', p.camas_indiv, 'sofas_cama', p.sofas_cama, 'banos', p.banos,
      'foto', (select f.ruta from public.fotos_cierre f where f.limpieza_id = b.limpieza_id and f.sala = 'bolsa'))
      order by (c.hora_entrada is not null) desc, c.hora_entrada, p.codigo)
    from public.bolsas b join public.limpiezas l on l.id = b.limpieza_id join public.propiedades p on p.id = b.propiedad_id
    join public.checkouts c on c.id = l.checkout_id left join public.perfiles d on d.id = b.driver left join public.perfiles rp on rp.id = b.recibida_por
    where b.fecha = p_fecha), '[]'::jsonb);
end $$;

commit;
