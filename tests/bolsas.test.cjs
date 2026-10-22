// Etapa 2 · pruebas locales de contrato. No accede a Supabase ni producción.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const read = p => fs.readFileSync(path.join(__dirname,'..',p),'utf8');
const html = read('index.html');
const migration = read('supabase/migraciones/36-PEGAR-contenido_recepcion_bolsas.sql');
const tests = read('supabase/migraciones/37-PEGAR-pruebas_bolsas.sql');
let passed=0;
const check=(label,fn)=>{fn();passed++;console.log('OK '+label);};
check('Todos los scripts JavaScript de index.html compilan',()=>{
  const scripts=[...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)].map(x=>x[1]).filter(Boolean);
  assert.ok(scripts.length>0);
  for(let i=0;i<scripts.length;i++)new vm.Script(scripts[i],{filename:'index.html#'+i});
});
check('PILOTO: el frontend solo apunta a Supabase de PRUEBAS',()=>{
  assert.match(html,/const PILOT_PROJECT_REF = 'yxgilbgwuxmlbdrbfisi'/);
  assert.match(html,/PILOTO DE PRUEBAS/);
  assert.match(html,/SUPABASE_URL = 'https:\/\/' \+ PILOT_PROJECT_REF/);
  assert.match(html,/storage:window\.sessionStorage/);
  assert.match(html,/pilotStorage/);
  assert.match(html,/!PILOT_MODE/);
  assert.doesNotMatch(html,/zxsiantglodsqqvigndk/);
  assert.doesNotMatch(html,/sb_publishable_f8nqvfRG75TZLMClqT2uZw_mch9Qcid/);
  assert.doesNotMatch(html,/serviceWorker\.register\('sw\.js'\)/);
});
check('SQL36 mantiene guardas de entorno y rechaza producción',()=>{
  assert.match(migration,/opsflow_entorno/);assert.match(migration,/v_tipo is distinct from 'pruebas'/);
  assert.match(migration,/if v = '[a-z]{20}' then/);
});
check('No fija kits por temporada ni cantidades ficticias',()=>{
  assert.match(html,/planificación|Checkout:|checkouts|Plan diario/);
  assert.match(migration,/conte[nn]ido jsonb/);
  assert.match(html,/const cant = \{ \.\.\.\(b\.contenido \|\| \{\}\) \}/);
});
check('El SQL valida catálogo de artículos y cantidades enteras',()=>{
  assert.match(migration,/public\._linens_nombre\(v\.key\)/);
  assert.match(migration,/jsonb_typeof\(v\.value\)/);
  assert.match(migration,/cannot|superar 50/);
});
check('El contenido se bloquea tras recogida y no lo edita Operación',()=>{
  assert.match(migration,/public\._es_lider\('Linens'\)/);
  assert.match(migration,/v\.estado not in \('por_preparar','preparada'\)/);
});
check('El driver escanea, entrega y tiene historial de custodia',()=>{
  for(const k of ['escanear_bolsa','entregar_bolsa','no_pude_entregar_bolsa']){
    assert.match(migration,new RegExp('create or replace function public\\.'+k+'\\('));
  }
  assert.match(migration,/'recogida'/);assert.match(migration,/'entregada'/);
});
check('La recepción solo la confirma el cleaner asignado',()=>{
  assert.match(migration,/public\.mi_departamento\(\) is distinct from 'Limpieza'/);
  assert.match(migration,/public\._soy_miembro\(l\.id\)/);
  assert.match(migration,/for update;/i);
});
check('Recepción idempotente con índice único y una tarea por bolsa',()=>{
  assert.match(migration,/recepcion_idempotencia uuid/);
  assert.match(migration,/bolsas_recepcion_idempotencia/);
  assert.match(migration,/pendientes_un_faltante_por_bolsa/);
  assert.match(migration,/if v\.estado = 'recibida' then/);
});
check('La entrega no certificada queda registrada sin inventar confirmación',()=>{
  assert.match(migration,/sin_entrega := v\.estado = 'en_camion'/);
  assert.match(migration,/entrega_sin_confirmar=sin_entrega/);
});
check('La cantidad recibida y las diferencias se calculan por artículo',()=>{
  assert.match(migration,/q-falt\+sobr/);
  assert.match(migration,/sobr-falt/);
});
check('Cleaning puede reportar linen needed por separado',()=>{
  assert.match(html,/db\.rpc\('reportar_linens'/);
  assert.match(html,/db\.rpc\('recibir_bolsa'/);
});
check('La cola offline usa un identificador por bolsa y no duplica recepciones',()=>{
  assert.match(html,/recibir:\$\{e\.args\.p_bolsa\}/);
  assert.match(html,/opsflow-recepcion-/);
  assert.match(html,/crypto\.randomUUID\(\)/);
});
check('SQL37 contiene comprobaciones con rollback y sin escrituras en producción',()=>{
  assert.match(tests,/FIN_PRUEBAS_BOLSAS/);
  assert.match(tests,/entorno de PRUEBAS no verificado/);
  assert.match(tests,/Rollback: ningún usuario/);
});
console.log('\n'+passed+' pruebas locales OK');
