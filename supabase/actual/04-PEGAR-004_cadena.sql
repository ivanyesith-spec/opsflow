-- OpsFlow · modulo cadena-checkout · 004
-- Limpiezas (una por checkout, automaticas), pendientes, registro de eventos
-- y las funciones de cada boton. Se ejecuta UNA vez: SQL Editor → pegar todo → Run.

-- 1. Tipos ---------------------------------------------------------------
create type public.estado_limpieza  as enum ('sin_asignar', 'asignada', 'en_curso', 'terminada', 'no_pude_entrar');
create type public.tipo_limpieza    as enum ('normal', 'refresh', 'deep', 'huesped_dentro', 'foto', 'post_mantenimiento');
create type public.tipo_pendiente   as enum ('linens', 'recogida', 'otro');
create type public.estado_pendiente as enum ('abierto', 'preparado', 'entregado', 'cerrado');

-- 2. Tablas --------------------------------------------------------------
create table public.limpiezas (
  id            uuid primary key default gen_random_uuid(),
  checkout_id   uuid not null unique references public.checkouts(id) on delete cascade,
  propiedad_id  uuid not null references public.propiedades(id),
  zona          public.zona not null,
  fecha         date not null,
  tipo          public.tipo_limpieza not null default 'normal',
  estado        public.estado_limpieza not null default 'sin_asignar',
  asignada_a    uuid references public.perfiles(id),
  orden         int check (orden between 1 and 50),
  publicada     boolean not null default false,
  inicio        timestamptz,
  fin           timestamptz,
  motivo_no_entrar text,
  es_prueba     boolean not null default false,
  creado_en     timestamptz not null default now()
);
create index limpiezas_fecha on public.limpiezas (fecha);

create table public.pendientes (
  id            uuid primary key default gen_random_uuid(),
  limpieza_id   uuid not null references public.limpiezas(id) on delete cascade,
  propiedad_id  uuid not null references public.propiedades(id),
  zona          public.zona not null,
  fecha         date not null,
  tipo          public.tipo_pendiente not null,
  detalle       text not null check (length(detalle) between 1 and 200),
  cantidad      int not null default 1 check (cantidad between 1 and 50),
  prioritario   boolean not null default false,
  estado        public.estado_pendiente not null default 'abierto',
  creado_por    uuid, creado_en    timestamptz not null default now(),
  preparado_por uuid, preparado_en timestamptz,
  entregado_por uuid, entregado_en timestamptz,
  cerrado_por   uuid, cerrado_en   timestamptz,
  es_prueba     boolean not null default false
);
create index pendientes_fecha on public.pendientes (fecha);

create table public.eventos (
  id            bigint generated always as identity primary key,
  cuando        timestamptz not null default now(),
  quien         uuid,
  que           text not null,
  limpieza_id   uuid references public.limpiezas(id) on delete cascade,
  pendiente_id  uuid references public.pendientes(id) on delete cascade
);

-- Nadie escribe estas tablas directamente: solo las funciones de abajo.
alter table public.limpiezas  enable row level security;
alter table public.pendientes enable row level security;
alter table public.eventos    enable row level security;
revoke all on public.limpiezas, public.pendientes, public.eventos from anon;
revoke insert, update, delete, truncate on public.limpiezas, public.pendientes, public.eventos from authenticated;

-- 3. Ayudante: zona de quien esta conectado -------------------------------
create or replace function public.mi_zona()
returns public.zona language sql stable security definer set search_path = ''
as $$ select zona from public.perfiles where id = (select auth.uid()) and activo $$;
revoke execute on function public.mi_zona() from public, anon;
grant  execute on function public.mi_zona() to authenticated;

-- 4. Quien ve que ---------------------------------------------------------
create policy "limpiezas: lectura por rol" on public.limpiezas for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) in ('Limpieza', 'Drivers'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and publicada and asignada_a = (select auth.uid()))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and publicada and zona = (select public.mi_zona()))
);

create policy "pendientes: lectura por rol" on public.pendientes for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Limpieza')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Linens' and tipo = 'linens')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Drivers' and tipo in ('linens', 'recogida'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and limpieza_id in (select id from public.limpiezas where asignada_a = (select auth.uid())))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and zona = (select public.mi_zona())
       and (tipo = 'recogida' or (tipo = 'linens' and estado <> 'abierto')))
);

create policy "eventos: solo operacion" on public.eventos for select to authenticated
using ((select public.mi_nivel()) = 'operacion');

-- 5. Cada checkout crea su limpieza ---------------------------------------
create or replace function public.crear_limpieza_de_checkout()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.limpiezas (checkout_id, propiedad_id, zona, fecha, es_prueba)
  select new.id, new.propiedad_id, p.zona, new.fecha, new.es_prueba
  from public.propiedades p where p.id = new.propiedad_id
  on conflict (checkout_id) do nothing;
  return new;
end $$;

create trigger checkout_crea_limpieza
after insert on public.checkouts
for each row execute function public.crear_limpieza_de_checkout();

-- Los checkouts que ya estaban cargados tambien reciben su limpieza
insert into public.limpiezas (checkout_id, propiedad_id, zona, fecha, es_prueba)
select c.id, c.propiedad_id, p.zona, c.fecha, c.es_prueba
from public.checkouts c join public.propiedades p on p.id = c.propiedad_id
on conflict (checkout_id) do nothing;

-- 6. Funciones de los botones ---------------------------------------------
-- Todas: comprueban quien llama y que el paso es valido, y dejan un evento.

create or replace function public._evento(p_que text, p_limpieza uuid, p_pendiente uuid)
returns void language sql security definer set search_path = ''
as $$ insert into public.eventos (quien, que, limpieza_id, pendiente_id) values ((select auth.uid()), p_que, p_limpieza, p_pendiente) $$;
revoke execute on function public._evento(text, uuid, uuid) from public, anon, authenticated;

create or replace function public._lider_limpieza()
returns boolean language sql stable security definer set search_path = ''
as $$ select public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Limpieza') $$;
revoke execute on function public._lider_limpieza() from public, anon, authenticated;

-- Asignar cleaner, orden y tipo (lider de limpieza u Operacion)
create or replace function public.asignar_limpieza(p_id uuid, p_cleaner uuid, p_orden int, p_tipo public.tipo_limpieza)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación asignan limpiezas.'; end if;
  select * into v from public.limpiezas where id = p_id for update;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if v.estado not in ('sin_asignar', 'asignada') then raise exception 'Esa limpieza ya empezó: no se puede reasignar.'; end if;
  if p_cleaner is not null and not exists (
       select 1 from public.perfiles where id = p_cleaner and activo and departamento = 'Limpieza' and nivel = 'operador') then
    raise exception 'Solo se puede asignar a un cleaner activo.';
  end if;
  update public.limpiezas
     set asignada_a = p_cleaner, orden = p_orden, tipo = coalesce(p_tipo, tipo),
         estado = case when p_cleaner is null then 'sin_asignar' else 'asignada' end::public.estado_limpieza,
         publicada = case when p_cleaner is null then false else publicada end
   where id = p_id;
  perform public._evento('asignada', p_id, null);
end $$;

-- Publicar el orden del dia: el cleaner solo ve lo publicado
create or replace function public.publicar_orden(p_fecha date)
returns int language plpgsql security definer set search_path = ''
as $$
declare n int;
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación publican el orden.'; end if;
  update public.limpiezas set publicada = true
   where fecha = p_fecha and asignada_a is not null and not publicada;
  get diagnostics n = row_count;
  insert into public.eventos (quien, que) values ((select auth.uid()), 'orden publicado ' || p_fecha || ' (' || n || ')');
  return n;
end $$;

-- Cleaner: empezar, terminar, no pude entrar
create or replace function public._mi_limpieza(p_id uuid)
returns public.limpiezas language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id for update;
  if not found or v.asignada_a is distinct from (select auth.uid()) or not v.publicada
     or public.mi_nivel() is null then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return v;
end $$;
revoke execute on function public._mi_limpieza(uuid) from public, anon, authenticated;

create or replace function public.iniciar_limpieza(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'asignada' then raise exception 'Solo se puede empezar una limpieza asignada.'; end if;
  update public.limpiezas set estado = 'en_curso', inicio = now() where id = p_id;
  perform public._evento('limpieza iniciada', p_id, null);
end $$;

create or replace function public.terminar_limpieza(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  update public.limpiezas set estado = 'terminada', fin = now() where id = p_id;
  perform public._evento('limpieza terminada', p_id, null);
end $$;

create or replace function public.no_pude_entrar(p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado not in ('asignada', 'en_curso') then raise exception 'Esta limpieza ya está cerrada.'; end if;
  if coalesce(btrim(p_motivo), '') = '' then raise exception 'Falta el motivo.'; end if;
  update public.limpiezas set estado = 'no_pude_entrar', motivo_no_entrar = left(btrim(p_motivo), 200), fin = now() where id = p_id;
  perform public._evento('no pude entrar: ' || left(btrim(p_motivo), 200), p_id, null);
end $$;

-- Cleaner (o lider de limpieza): reportar un pendiente
create or replace function public.reportar_pendiente(p_limpieza uuid, p_tipo public.tipo_pendiente, p_detalle text, p_cantidad int default 1)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_prio boolean; v_id uuid;
begin
  select * into v from public.limpiezas where id = p_limpieza;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if not public._lider_limpieza() and (v.asignada_a is distinct from (select auth.uid()) or not v.publicada) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  if v.estado not in ('en_curso', 'terminada') then raise exception 'Primero hay que empezar la limpieza.'; end if;
  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba)
  values (v.id, v.propiedad_id, v.zona, v.fecha, p_tipo,
          coalesce(nullif(btrim(p_detalle), ''), case when p_tipo = 'recogida' then 'Basura y linens sucios' end),
          coalesce(p_cantidad, 1), coalesce(v_prio, false), (select auth.uid()), v.es_prueba)
  returning id into v_id;
  perform public._evento('pendiente reportado (' || p_tipo || ')', v.id, v_id);
  return v_id;
end $$;

-- Lider de linens: preparado
create or replace function public.marcar_preparado(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Linens')) then
    raise exception 'Solo linens u Operación marcan preparado.';
  end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or v.tipo <> 'linens' then raise exception 'Ese pendiente no es de linens.'; end if;
  if v.estado <> 'abierto' then raise exception 'Ese pendiente ya está preparado.'; end if;
  update public.pendientes set estado = 'preparado', preparado_por = (select auth.uid()), preparado_en = now() where id = p_id;
  perform public._evento('preparado por linens', v.limpieza_id, p_id);
end $$;

-- Driver: entregado (linens) o recogido (recogida)
create or replace function public.marcar_entregado(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  if not (public.mi_nivel() = 'operacion'
          or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')
          or (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers' and public.mi_zona() = v.zona)) then
    raise exception 'Solo el driver de la zona puede marcar la entrega.';
  end if;
  if v.tipo = 'linens' and v.estado = 'preparado' then
    update public.pendientes set estado = 'entregado', entregado_por = (select auth.uid()), entregado_en = now() where id = p_id;
    perform public._evento('entregado por driver', v.limpieza_id, p_id);
  elsif v.tipo = 'recogida' and v.estado = 'abierto' then
    update public.pendientes set estado = 'cerrado', entregado_por = (select auth.uid()), entregado_en = now(),
                                 cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
    perform public._evento('recogido por driver', v.limpieza_id, p_id);
  else
    raise exception 'Ese pendiente todavía no está listo para el driver.';
  end if;
end $$;

-- Cleaner: recibido → cerrado (decision: solo el cleaner cierra)
create or replace function public.marcar_recibido(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes; v_dueno uuid;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  select asignada_a into v_dueno from public.limpiezas where id = v.limpieza_id;
  if v_dueno is distinct from (select auth.uid()) or public.mi_nivel() is null then
    raise exception 'Solo el cleaner de esta limpieza puede marcar recibido.';
  end if;
  if v.tipo <> 'linens' or v.estado <> 'entregado' then raise exception 'Todavía no se ha entregado.'; end if;
  update public.pendientes set estado = 'cerrado', cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
  perform public._evento('recibido por cleaner: cerrado', v.limpieza_id, p_id);
end $$;

-- Lider de limpieza u Operacion: resolver un pendiente de tipo "otro"
create or replace function public.resolver_pendiente(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación lo resuelven.'; end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or v.tipo <> 'otro' or v.estado <> 'abierto' then raise exception 'Ese pendiente no se puede resolver así.'; end if;
  update public.pendientes set estado = 'cerrado', cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
  perform public._evento('resuelto por líder', v.limpieza_id, p_id);
end $$;

-- 7. Pantallas del campo (devuelven todo lo que necesita el telefono) ------
create or replace function public.mi_dia(p_fecha date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x->>'orden')::int nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', l.id, 'orden', l.orden, 'tipo', l.tipo, 'estado', l.estado, 'motivo', l.motivo_no_entrar,
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'camas_dobles', p.camas_dobles, 'camas_indiv', p.camas_indiv, 'sofas', p.sofas_cama, 'banos', p.banos, 'notas', p.notas,
      'salida', to_char(c.hora_salida, 'HH24:MI'), 'entrada', to_char(c.hora_entrada, 'HH24:MI'),
      'pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle,
                     'cantidad', pe.cantidad, 'estado', pe.estado) order by pe.creado_en)
                     from public.pendientes pe where pe.limpieza_id = l.id), '[]'::jsonb)) x
    from public.limpiezas l
    join public.propiedades p on p.id = l.propiedad_id
    join public.checkouts c on c.id = l.checkout_id
    where l.fecha = p_fecha and l.publicada and l.asignada_a = (select auth.uid())
      and public.mi_nivel() is not null
  ) t
$$;

create or replace function public.mi_ruta(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_zona public.zona := public.mi_zona();
begin
  if not (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers') then
    raise exception 'Esta pantalla es para drivers.';
  end if;
  return jsonb_build_object(
    'tareas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'estado', pe.estado,
        'prioritario', pe.prioritario, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'))
        order by pe.prioritario desc, pe.creado_en)
      from public.pendientes pe
      join public.limpiezas l on l.id = pe.limpieza_id
      join public.propiedades p on p.id = pe.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where pe.fecha = p_fecha and pe.zona = v_zona
        and ((pe.tipo = 'linens' and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto'))), '[]'::jsonb),
    'orden', coalesce((select jsonb_agg(jsonb_build_object(
        'cleaner', pf.nombre, 'orden', l.orden, 'estado', l.estado, 'codigo', p.codigo, 'nombre', p.nombre,
        'pueblo', p.pueblo, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'))
        order by pf.nombre, l.orden)
      from public.limpiezas l
      join public.propiedades p on p.id = l.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      join public.perfiles pf on pf.id = l.asignada_a
      where l.fecha = p_fecha and l.zona = v_zona and l.publicada), '[]'::jsonb));
end $$;

-- 8. Tablero de Operacion -------------------------------------------------
create or replace function public.tablero(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'El tablero es de Operación.'; end if;
  return jsonb_build_object(
    'limpiezas', (select coalesce(jsonb_object_agg(estado, n), '{}'::jsonb)
                  from (select estado, count(*) n from public.limpiezas where fecha = p_fecha group by estado) a),
    'sin_publicar', (select count(*) from public.limpiezas where fecha = p_fecha and asignada_a is not null and not publicada),
    'en_linens',   (select count(*) from public.pendientes where fecha = p_fecha and tipo = 'linens' and estado = 'abierto'),
    'en_driver',   (select count(*) from public.pendientes where fecha = p_fecha and ((tipo = 'linens' and estado = 'preparado') or (tipo = 'recogida' and estado = 'abierto'))),
    'por_recibir', (select count(*) from public.pendientes where fecha = p_fecha and tipo = 'linens' and estado = 'entregado'),
    'otros_abiertos', (select count(*) from public.pendientes where fecha = p_fecha and tipo = 'otro' and estado = 'abierto'),
    'cerrados',    (select count(*) from public.pendientes where fecha = p_fecha and estado = 'cerrado'),
    'minutos_cierre', (select round(avg(extract(epoch from cerrado_en - creado_en)) / 60)
                       from public.pendientes where fecha = p_fecha and estado = 'cerrado'),
    'no_pude_entrar', (select coalesce(jsonb_agg(jsonb_build_object('codigo', p.codigo, 'nombre', p.nombre, 'motivo', l.motivo_no_entrar)), '[]'::jsonb)
                       from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
                       where l.fecha = p_fecha and l.estado = 'no_pude_entrar'));
end $$;

-- 9. Permisos de las funciones --------------------------------------------
revoke execute on function
  public.crear_limpieza_de_checkout(),
  public.asignar_limpieza(uuid, uuid, int, public.tipo_limpieza), public.publicar_orden(date),
  public.iniciar_limpieza(uuid), public.terminar_limpieza(uuid), public.no_pude_entrar(uuid, text),
  public.reportar_pendiente(uuid, public.tipo_pendiente, text, int),
  public.marcar_preparado(uuid), public.marcar_entregado(uuid), public.marcar_recibido(uuid), public.resolver_pendiente(uuid),
  public.mi_dia(date), public.mi_ruta(date), public.tablero(date)
from public, anon;
grant execute on function
  public.asignar_limpieza(uuid, uuid, int, public.tipo_limpieza), public.publicar_orden(date),
  public.iniciar_limpieza(uuid), public.terminar_limpieza(uuid), public.no_pude_entrar(uuid, text),
  public.reportar_pendiente(uuid, public.tipo_pendiente, text, int),
  public.marcar_preparado(uuid), public.marcar_entregado(uuid), public.marcar_recibido(uuid), public.resolver_pendiente(uuid),
  public.mi_dia(date), public.mi_ruta(date), public.tablero(date)
to authenticated;
