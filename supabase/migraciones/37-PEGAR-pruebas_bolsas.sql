-- OpsFlow · 37 · Pruebas SQL para migración 36 · EXCLUSIVAMENTE en Supabase PRUEBAS
-- No tocar Supabase producción. Los datos se revierten usando subtransacción interna.
select set_config('opsflow.proyecto','ESCRIBE-AQUI-EL-ID-DEL-PROYECTO',false);
do $$
declare v text:=current_setting('opsflow.proyecto',true); t text; p text;
begin
  if v is null or v !~ '^[a-z]{20}$' or v = 'zxsiantglodsqqvigndk'
    then raise exception 'PARADO: identificador del proyecto de pruebas inválido.'; end if;
  if to_regclass('public.opsflow_entorno') is not null
    then execute 'select tipo,proyecto from public.opsflow_entorno where id=1' into t,p; end if;
  if t is distinct from 'pruebas' or p is distinct from v
    then raise exception 'PARADO: entorno de PRUEBAS no verificado.'; end if;
  if to_regprocedure('public.recibir_bolsa(uuid,jsonb,jsonb,uuid)') is null
    then raise exception 'Falta ejecutar primero migración 36.'; end if;
  if exists(select 1 from public.propiedades where not es_prueba)
    then raise exception 'PARADO: existen propiedades reales.'; end if;
end $$;
create temp table if not exists resultados_bolsas(n int,prueba text,resultado text);
truncate resultados_bolsas;

create or replace function pg_temp.como_bolsa(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role','none',true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',uid::text,'role','authenticated')::text,true);
  perform set_config('role','authenticated',true);
end $$;
create or replace function pg_temp.yo_bolsa() returns void language plpgsql as $$
begin perform set_config('role','none',true); end $$;
create or replace function pg_temp.falla_bolsa(q text,codigo text,fragmento text)
returns text language plpgsql as $$
declare c text; m text;
begin
  execute q; return 'La operación se permitió inesperadamente.';
exception when others then
  get stacked diagnostics c=returned_sqlstate,m=message_text;
  if c=codigo and position(fragmento in m)>0 then return null; end if;
  return 'Error distinto: '||c||' · '||m;
end $$;
create or replace function pg_temp.prueba_bolsa(n int,nombre text,correcto boolean,detalle text default '')
returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('n',n,'prueba',nombre,
   'resultado',case when coalesce(correcto,false) then 'OK' else 'FALLO '||coalesce(detalle,'') end))
$$;
create or replace function pg_temp.errores_bolsa(n int,nombre text,a text[])
returns jsonb language sql as $$
 select pg_temp.prueba_bolsa(n,nombre,coalesce(array_length(array_remove(a,null),1),0)=0,
   array_to_string(array_remove(a,null),' | '))
$$;

do $$
declare
  o uuid:='00000000-0000-0000-0000-000000003601';
  ll uuid:='00000000-0000-0000-0000-000000003602';
  dl uuid:='00000000-0000-0000-0000-000000003603';
  cl uuid:='00000000-0000-0000-0000-000000003604';
  bad uuid:='00000000-0000-0000-0000-000000003605';
  lin uuid:='00000000-0000-0000-0000-000000003606';
  R jsonb:='[]'::jsonb;
  a uuid; b uuid; la uuid; lb uuid; order_id uuid;
  x jsonb; key1 uuid; key2 uuid; n int; err text;
begin
  begin
    insert into auth.users(id,email,aud,role) values
      (o,'sql37.operation@opsflow.test','authenticated','authenticated'),
      (ll,'sql37.linensleader@opsflow.test','authenticated','authenticated'),
      (dl,'sql37.driver@opsflow.test','authenticated','authenticated'),
      (cl,'sql37.cleaner@opsflow.test','authenticated','authenticated'),
      (bad,'sql37.othercleaner@opsflow.test','authenticated','authenticated'),
      (lin,'sql37.cleaningleader@opsflow.test','authenticated','authenticated');
    insert into public.perfiles(id,nombre,departamento,nivel,zona,idioma) values
      (o,'SQL37 Operacion','Operación','operacion',null,'es'),
      (ll,'SQL37 Linens','Linens','lider',null,'es'),
      (dl,'SQL37 Driver','Drivers','operador','Norte','es'),
      (cl,'SQL37 Cleaner','Limpieza','operador','Norte','es'),
      (bad,'SQL37 Other','Limpieza','operador','Norte','es'),
      (lin,'SQL37 Cleaning Leader','Limpieza','lider',null,'es');
    insert into public.propiedades(codigo,nombre,zona,pueblo,es_prueba)
    values ('TEST-E2A','Bolsa etapa 2 A','Norte','Prueba',true),
           ('TEST-E2B','Bolsa etapa 2 B','Norte','Prueba',true);
    perform pg_temp.como_bolsa(o);
    perform public.cargar_checkouts((now() at time zone 'Europe/Malta')::date,
      E'TEST-E2A 10:00\nTEST-E2B 10:00',true);
    perform pg_temp.yo_bolsa();
    select id into la from public.limpiezas where propiedad_id=(select id from public.propiedades where codigo='TEST-E2A');
    select id into lb from public.limpiezas where propiedad_id=(select id from public.propiedades where codigo='TEST-E2B');
    perform pg_temp.como_bolsa(lin);
    perform public.asignar_limpieza(la,cl,1,'normal');
    perform public.asignar_limpieza(lb,cl,2,'normal');
    perform public.publicar_orden((now() at time zone 'Europe/Malta')::date);
    perform pg_temp.yo_bolsa();
    -- El líder Linens consulta y crea las bolsas del día
    perform pg_temp.como_bolsa(ll);
    perform public.bolsas_dia((now() at time zone 'Europe/Malta')::date);
    perform pg_temp.yo_bolsa();
    select id into a from public.bolsas where limpieza_id=la;
    select id into b from public.bolsas where limpieza_id=lb;
    R:=R||pg_temp.prueba_bolsa(1,'Bolsa única por limpieza',a is not null and b is not null and a<>b);
    perform pg_temp.como_bolsa(o);
    R:=R||pg_temp.errores_bolsa(2,'Operación no prepara',array[
       pg_temp.falla_bolsa(format('select public.guardar_contenido_bolsa(%L,%L::jsonb,true)',
          a,'{"sabana_doble":2}'),'42501','Solo el líder de Linens')]);
    perform pg_temp.como_bolsa(ll);
    R:=R||pg_temp.errores_bolsa(3,'Rechaza artículo inventado',array[
       pg_temp.falla_bolsa(format('select public.guardar_contenido_bolsa(%L,%L::jsonb,true)',
          a,'{"producto_que_no_existe":1}'),'22023','Artículo o cantidad')]);
    R:=R||pg_temp.errores_bolsa(4,'Rechaza cantidades mayores de 50',array[
       pg_temp.falla_bolsa(format('select public.guardar_contenido_bolsa(%L,%L::jsonb,true)',
          a,'{"sabana_doble":51}'),'22023','cantidad')]);
    x:=public.guardar_contenido_bolsa(a,'{"sabana_doble":2,"toalla_grande":3}'::jsonb,true);
    R:=R||pg_temp.prueba_bolsa(5,'Linens prepara con contenido y cantidades',x->>'estado'='preparada'
      and (select contenido->>'sabana_doble' from public.bolsas where id=a)='2');
    perform public.guardar_contenido_bolsa(a,'{"sabana_doble":2,"toalla_grande":2}'::jsonb,true);
    R:=R||pg_temp.prueba_bolsa(6,'Linens corrige antes del escaneo con historial',
       (select jsonb_array_length(historial)>=2 and contenido->>'toalla_grande'='2' from public.bolsas where id=a));
    perform public.guardar_contenido_bolsa(b,'{"sabana_doble":1,"toalla_grande":2}'::jsonb,true);
    perform pg_temp.como_bolsa(dl);
    R:=R||pg_temp.errores_bolsa(7,'Driver no edita contenido',array[
       pg_temp.falla_bolsa(format('select public.guardar_contenido_bolsa(%L,%L::jsonb,true)',
          a,'{"sabana_doble":9}'),'42501','Solo el líder de Linens')]);
    perform pg_temp.yo_bolsa();
    perform pg_temp.como_bolsa(ll);
    select qr into err from public.bolsas_etiquetas((now() at time zone 'Europe/Malta')::date) where codigo='TEST-E2A';
    perform pg_temp.como_bolsa(dl);
    perform public.escanear_bolsa(err);
    R:=R||pg_temp.prueba_bolsa(8,'Driver recibe custodia por QR',
      (select estado='en_camion' and driver=dl and recogida_en is not null from public.bolsas where id=a));
    perform pg_temp.como_bolsa(ll);
    R:=R||pg_temp.errores_bolsa(9,'Contenido bloqueado después del escaneo',array[
      pg_temp.falla_bolsa(format('select public.guardar_contenido_bolsa(%L,%L::jsonb,true)',
       a,'{"sabana_doble":8}'),'22023','contenido ya está bloqueado')]);
    perform pg_temp.como_bolsa(o);
    R:=R||pg_temp.errores_bolsa(10,'Operación no confirma recepción',array[
      pg_temp.falla_bolsa(format('select public.recibir_bolsa(%L,%L::jsonb,%L::jsonb,%L)',
        a,'{}','{}',gen_random_uuid()),'42501','Solo un cleaner')]);
    perform pg_temp.yo_bolsa();
    update public.limpiezas set estado='en_curso' where id in (la,lb);
    perform pg_temp.como_bolsa(bad);
    R:=R||pg_temp.errores_bolsa(11,'Cleaner ajeno no puede recibir',array[
      pg_temp.falla_bolsa(format('select public.recibir_bolsa(%L,%L::jsonb,%L::jsonb,%L)',
        a,'{}','{}',gen_random_uuid()),'42501','no corresponde')]);
    perform pg_temp.como_bolsa(cl);
    R:=R||pg_temp.errores_bolsa(12,'Faltante superior a lo preparado rechazado',array[
      pg_temp.falla_bolsa(format('select public.recibir_bolsa(%L,%L::jsonb,%L::jsonb,%L)',
       a,'{"sabana_doble":3}','{}',gen_random_uuid()),'22023','supera')]);
    key1:=gen_random_uuid();
    x:=public.recibir_bolsa(a,'{"toalla_grande":1}'::jsonb,'{}'::jsonb,key1);
    order_id:=(x->>'pendiente_id')::uuid;
    R:=R||pg_temp.prueba_bolsa(13,'Cleaner recibe aunque driver no marcó la entrega',
      x->>'estado'='recibida' and (x->>'entrega_sin_confirmar')::boolean
      and (select entrega_sin_confirmar from public.bolsas where id=a));
    R:=R||pg_temp.prueba_bolsa(14,'Faltantes crean UN pendiente vinculado',
      order_id is not null and (select count(*) from public.pendientes where bolsa_id=a)=1);
    R:=R||pg_temp.prueba_bolsa(15,'Cantidades y diferencias correctas',
      (select recibido->>'toalla_grande'='1' and diferencia->>'toalla_grande'='-1' from public.bolsas where id=a));
    x:=public.recibir_bolsa(a,'{}'::jsonb,'{}'::jsonb,key1);
    R:=R||pg_temp.prueba_bolsa(16,'Reintento idempotente no duplica faltante',
      (x->>'ya_registrada')::boolean and (select count(*) from public.pendientes where bolsa_id=a)=1);
    perform pg_temp.como_bolsa(ll);
    select qr into err from public.bolsas_etiquetas((now() at time zone 'Europe/Malta')::date) where codigo='TEST-E2B';
    perform pg_temp.como_bolsa(dl);
    perform public.escanear_bolsa(err);
    -- Segunda bolsa: se comprueba el flujo de entrega con foto simulada dentro de este proyecto de pruebas
    perform public.entregar_bolsa(b,lb::text||'/bolsa.jpg','Foto de prueba');
    perform pg_temp.como_bolsa(cl);
    key2:=gen_random_uuid();
    x:=public.recibir_bolsa(b,'{}'::jsonb,'{"toalla_cocina":1}'::jsonb,key2);
    R:=R||pg_temp.prueba_bolsa(17,'Sobrante queda registrado sin pendiente',
      x->'diferencia'->>'toalla_cocina'='1'
      and (select count(*) from public.pendientes where bolsa_id=b)=0);
    R:=R||pg_temp.prueba_bolsa(18,'Entrega confirmada distinta de recepción',
      not (x->>'entrega_sin_confirmar')::boolean and
      (select entregada_en is not null and recibida_en is not null from public.bolsas where id=b));
    perform pg_temp.como_bolsa(o);
    x:=public.resumen_linens_dia((now() at time zone 'Europe/Malta')::date);
    R:=R||pg_temp.prueba_bolsa(19,'Demanda del día basada en dos checkouts',
      (x->>'checkouts')::int=2 and (x->>'recibidas')::int=2
      and (x->'cantidades_confirmadas'->>'sabana_doble')::int=3);
    x:=public.historial_bolsa(a);
    R:=R||pg_temp.prueba_bolsa(20,'Historial por bolsa auditable',jsonb_array_length(x)>=4);
    perform pg_temp.como_bolsa(dl);
    R:=R||pg_temp.errores_bolsa(21,'Driver no puede consultar historial de líder',array[
      pg_temp.falla_bolsa(format('select public.historial_bolsa(%L)',a),
      '42501','No tienes permiso')]);
    perform pg_temp.yo_bolsa();
    raise exception 'FIN_PRUEBAS_BOLSAS'; -- rollback deliberado; conserva R en variable PL/pgSQL
  exception when others then
    if sqlerrm <> 'FIN_PRUEBAS_BOLSAS' then
      R:=R||pg_temp.prueba_bolsa(0,'Error inesperado: pruebas interrumpidas',false,sqlstate||': '||sqlerrm);
    end if;
  end;
  perform pg_temp.yo_bolsa();
  insert into resultados_bolsas select (e->>'n')::int,e->>'prueba',e->>'resultado'
    from jsonb_array_elements(R) e;
end $$;
insert into resultados_bolsas
select 22,'Rollback: ningún usuario ni apartamento temporal persistió',
case when not exists(select 1 from auth.users where email like 'sql37.%@opsflow.test')
  and not exists(select 1 from public.propiedades where codigo in ('TEST-E2A','TEST-E2B'))
then 'OK' else 'FALLO: quedaron datos de prueba' end;
select * from resultados_bolsas order by n;
