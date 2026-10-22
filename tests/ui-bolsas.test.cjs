// OpsFlow etapa 2: PRUEBAS REALES DE INTERFAZ (Chromium + Supabase simulado).
// No hay credenciales, tráfico al Supabase real, ni escrituras persistentes.
// Ejecutar: npm install --no-save playwright@1.55.1 && npx playwright install chromium && node tests/ui-bolsas.test.cjs
const assert = require('node:assert/strict');
const { createServer } = require('node:http');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { chromium } = require('playwright');

const ROOT = join(__dirname, '..');
const cleanId = '00000000-0000-0000-0000-000000007201';
const bagId = '00000000-0000-0000-0000-000000007202';
const testServer = createServer((req,res)=>{
  const path = new URL(req.url, 'http://127.0.0.1').pathname;
  const allowed = { '/':'index.html','/index.html':'index.html','/manifest.json':'manifest.json' };
  const file = allowed[path];
  if (!file) { res.writeHead(404); return res.end('not found'); }
  res.setHeader('Content-Type', path.endsWith('json') ? 'application/json' : 'text/html; charset=utf-8');
  res.setHeader('Cache-Control','no-store');
  res.end(readFileSync(join(ROOT,file)));
});

async function newPage(browser, base, scenario){
  const context=await browser.newContext({ viewport:{width:390,height:844}, serviceWorkers:'block', locale:'es-MT'});
  const page=await context.newPage();
  await page.addInitScript(({scenario,cleanId,bagId})=>{
    const role = scenario === 'cleaner' || scenario === 'offline' || scenario === 'extras' || scenario === 'missing' ? 'cleaner'
      : scenario === 'driver' ? 'driver' : scenario === 'operation' ? 'operation' : scenario === 'substitute' ? 'substitute' : 'linens';
    const profiles={
      linens:{id:'00000000-0000-0000-0000-000000007210',nombre:'Linens Test',departamento:'Linens',nivel:'lider'},
      substitute:{id:'00000000-0000-0000-0000-000000007211',nombre:'Linens Substitute',departamento:'Linens',nivel:'operador'},
      operation:{id:'00000000-0000-0000-0000-000000007212',nombre:'Operations Test',departamento:'Operación',nivel:'operacion'},
      cleaner:{id:'00000000-0000-0000-0000-000000007213',nombre:'Cleaner Test',departamento:'Limpieza',nivel:'operador'},
      driver:{id:'00000000-0000-0000-0000-000000007214',nombre:'Driver Test',departamento:'Drivers',nivel:'operador'}
    };
    const profile={...profiles[role],activo:true,idioma:'es',zona:role==='driver'||role==='cleaner'?'Norte':null,debe_cambiar_clave:false};
    const bag = {id:bagId,limpieza_id:cleanId,estado:role==='cleaner'?'entregada':role==='driver'?'en_camion':'por_preparar',
      codigo:'QWR037',nombre:'Apartamento simulado',pueblo:'Qawra',zona:'Norte',camas_dobles:1,camas_indiv:0,
      sofas_cama:0,banos:1,contenido:role==='cleaner'?{sabana_doble:2,toalla_grande:2}:role==='driver'?{sabana_doble:2}:{},
      recibido:{},diferencia:{},historial:[],entrega_sin_confirmar:false,pendiente_estado:null,entrada:'15:00'};
    const cleanerWork={id:cleanId,estado:'en_curso',codigo:'QWR037',nombre:'Apartamento simulado',
      pueblo:'Qawra',banos:1,camas_dobles:1,camas_indiv:0,sofas:0,pendientes:[],presente:true,
      tipo:'normal',entrada:'15:00',salida:'11:00',bolsa:bag};
    const store={profile,bag,cleanerWork,rpcCalls:[],receiptCalls:[],offlineOnce:false,received:false};
    window.__opsflowMock=store;
    const summary=()=>{
      const counts={checkouts:1,sin_preparar:0,preparadas:0,en_camion:0,entregadas:0,recibidas:0,diferencias:0,cantidades_confirmadas:{}};
      counts[{por_preparar:'sin_preparar',preparada:'preparadas',en_camion:'en_camion',entregada:'entregadas',recibida:'recibidas'}[bag.estado]]++;
      if(bag.estado!=='por_preparar') counts.cantidades_confirmadas={...bag.contenido};
      return counts;
    };
    const mockRpc=async(name,args={})=>{
      store.rpcCalls.push({name,args:structuredClone(args)});
      if(name==='mi_sustitucion')return role==='substitute'?{departamento:'Linens',hasta:'2027-12-31T23:59:00Z'}:null;
      if(name==='bolsas_dia')return [{...bag}];
      if(name==='resumen_linens_dia')return summary();
      if(name==='guardar_contenido_bolsa'){
        if(role!=='linens' && role!=='substitute')throw Error('Sin permiso');
        bag.estado=args.p_lista?'preparada':'por_preparar';
        bag.contenido=structuredClone(args.p_contenido);
        return {id:bag.id,estado:bag.estado,contenido:bag.contenido};
      }
      if(name==='historial_bolsa')return bag.historial;
      if(name==='mi_dia')return [cleanerWork];
      if(name==='mi_checklist')return {presente:true,linens_revisado:store.received?'2026-10-22T10:00:00Z':null,
        equipo:[],pasos:[],salas:{},fotos:{},personas:1, inicio_qr:true};
      if(name==='bolsa_mia')return {id:bag.id,estado:bag.estado,contenido:bag.contenido,
        recibido:bag.recibido,diferencia:bag.diferencia,recibida_en:store.received?'2026-10-22T10:00:00Z':null};
      if(name==='recibir_bolsa'){
        store.receiptCalls.push(structuredClone(args));
        if(store.offlineOnce){store.offlineOnce=false;throw new Error('Failed to fetch');}
        if(store.received)return {id:bag.id,estado:'recibida',ya_registrada:true,diferencia:bag.diferencia};
        store.received=true;bag.estado='recibida';
        const keys=new Set([...Object.keys(bag.contenido),...Object.keys(args.p_sobrantes)]);
        bag.recibido={};bag.diferencia={};
        keys.forEach(k=>{
          bag.recibido[k]=(bag.contenido[k]||0)-(args.p_faltantes[k]||0)+(args.p_sobrantes[k]||0);
          const delta=bag.recibido[k]-(bag.contenido[k]||0);
          if(delta)bag.diferencia[k]=delta;
        });
        return {id:bag.id,estado:'recibida',ya_registrada:false,diferencia:bag.diferencia};
      }
      if(name==='tablero_zonas')return [];
      if(name==='mis_trabajos')return {bolsas:bag.estado==='en_camion'?[{...bag,limite:'11:00'}]:[],listas:[]};
      if(name==='mi_ruta')return {orden:[]};
      if(name==='trafico_actual')return {incidencias:[]};
      return [];
    };
    function query(table){
      const ret={
        select(){return ret},eq(){return ret},order(){return ret},gte(){return ret},lte(){return ret},
        maybeSingle:async()=>({data:table==='perfiles'?profile:null,error:null}),
        then(resolve,reject){return Promise.resolve({data:table==='pendientes'?[]:[],error:null}).then(resolve,reject);}
      };return ret;
    }
    const client={
      auth:{
        getSession:async()=>({data:{session:{user:{id:profile.id}}}}),
        getUser:async()=>({data:{user:{id:profile.id}}}),
        onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
        signOut:async()=>({})
      },
      from:query,
      rpc:async(name,args)=>({data:await mockRpc(name,args),error:null}),
      functions:{invoke:async()=>({data:{},error:null})},
      storage:{from:()=>({createSignedUrls:async()=>({data:[]}),upload:async()=>({data:{},error:null})})}
    };
    window.supabase={createClient:()=>client};
  },{scenario,cleanId,bagId});
  const outside=[];
  await page.route('**/*',route=>{
    const url=new URL(route.request().url());
    if(url.hostname==='127.0.0.1')return route.continue();
    outside.push(url.hostname);return route.abort();
  });
  const runtimeErrors=[];
  page.on('pageerror',e=>runtimeErrors.push(e.message));
  const query=scenario==='linens'||scenario==='operation'?'?v=linens':'';
  await page.goto(base+'/index.html'+query,{waitUntil:'domcontentloaded'});
  return {page,context,store:()=>page.evaluate(()=>({
    bag:window.__opsflowMock.bag, rpcCalls:window.__opsflowMock.rpcCalls,
    receiptCalls:window.__opsflowMock.receiptCalls,
    received:window.__opsflowMock.received,
    cola:JSON.parse(localStorage.getItem('opsflow-cola')||'[]')
  })),runtimeErrors,outside};
}
async function run(){
  const port=await new Promise(resolve=>testServer.listen(0,'127.0.0.1',()=>resolve(testServer.address().port)));
  const base='http://127.0.0.1:'+port;
  const browser=await chromium.launch({headless:true});
  let completed=0;
  async function test(name,scenario,fn){
    const t=await newPage(browser,base,scenario);
    try{
      await fn(t);assert.deepEqual(t.runtimeErrors,[],'errores JS de la interfaz');
      console.log('OK '+name);completed++;
    }finally{await t.context.close();}
  }
  try{
    await test('Linens: prepara contenido por apartamento y actualiza tablero','linens',async t=>{
      const p=t.page;
      await p.locator('[data-beditar]').first().waitFor();
      await p.locator('[data-beditar]').first().click();
      await p.locator('#bolItems [data-it="sabana_doble"] [data-mas]').click({clickCount:2,delay:100});
      await p.locator('#bolItems [data-it="toalla_grande"] [data-mas]').click();
      await p.locator('#bolGuardar').click();
      await p.getByText('Contenido:').first().waitFor();
      const st=await t.store();
      assert.equal(st.bag.estado,'preparada');
      assert.equal(st.bag.contenido.sabana_doble,2);
      assert.equal(st.bag.contenido.toalla_grande,1);
      assert.equal(st.rpcCalls.filter(x=>x.name==='guardar_contenido_bolsa').length,1);
    });
    await test('Operación: consulta Linens sin poder preparar una bolsa','operation',async t=>{
      await t.page.getByText('Plan diario').first().waitFor();
      assert.equal(await t.page.locator('[data-beditar]').count(),0);
    });
    await test('Sustituto de Linens: vista de líder y preparación disponible','substitute',async t=>{
      await t.page.locator('#modoBtn').click();
      await t.page.locator('nav.tabs [data-vista="linens"]').click();
      await t.page.locator('[data-beditar]').first().waitFor();
      assert.equal(await t.page.locator('[data-beditar]').count(),1);
    });
    await test('Cleaning: confirma faltante de toalla exactamente una vez','cleaner',async t=>{
      const p=t.page;
      await p.locator('[data-abrir]').first().click();
      await p.getByText('Expected content:').first().waitFor();
      await p.locator('#lcItems [data-it="toalla_grande"] [data-mas]').click();
      await p.locator('#lcEnviar').click();
      await p.getByText('Closing photos').first().waitFor();
      const st=await t.store();
      assert.equal(st.receiptCalls.length,1);
      assert.equal(st.receiptCalls[0].p_faltantes.toalla_grande,1);
      assert.equal(st.receiptCalls[0].p_sobrantes.toalla_grande,undefined);
      assert.equal(st.bag.diferencia.toalla_grande,-1);
    });
    await test('Cleaning: registra un sobrante sin faltante','extras',async t=>{
      const p=t.page;
      await p.locator('[data-abrir]').first().click();
      await p.locator('#lcExtra [data-it="toalla_cocina"] [data-mas]').click();
      await p.locator('#lcEnviar').click();
      await p.getByText('Closing photos').first().waitFor();
      const st=await t.store();
      assert.equal(st.receiptCalls.length,1);
      assert.equal(st.receiptCalls[0].p_sobrantes.toalla_cocina,1);
      assert.equal(st.bag.diferencia.toalla_cocina,1);
    });
    await test('Cleaning: sin señal, conserva el UUID y la recepción en cola','offline',async t=>{
      const p=t.page;
      await p.locator('[data-abrir]').first().click();
      await p.locator('#lcItems [data-it="toalla_grande"] [data-mas]').click();
      await p.evaluate(()=>{window.__opsflowMock.offlineOnce=true;});
      await p.locator('#lcEnviar').click();
      await p.getByText('Receipt saved on this phone').first().waitFor();
      const st=await t.store();
      assert.equal(st.receiptCalls.length,1);
      assert.equal(st.cola.length,1);
      assert.equal(st.cola[0].fn,'recibir_bolsa');
      assert.equal(st.cola[0].args.p_faltantes.toalla_grande,1);
      const uuid=st.cola[0].args.p_idempotencia;
      await p.evaluate(()=>window.dispatchEvent(new Event('online')));
      await p.waitForFunction(()=>JSON.parse(localStorage.getItem('opsflow-cola')||'[]').length===0);
      const after=await t.store();
      assert.equal(after.receiptCalls.length,2);
      assert.equal(after.receiptCalls[1].p_idempotencia,uuid);
      assert.equal(after.received,true);
    });
    await test('Driver: ve la bolsa en su camión sin editar contenido','driver',async t=>{
      const p=t.page;
      await p.locator('[data-sec="linens"]').click();
      await p.getByText('DELIVER LINENS BAG').first().waitFor();
      assert.equal(await p.locator('[data-beditar]').count(),0);
      assert.equal(await p.locator('[data-entbolsa]').count(),1);
    });
    console.log('UI aislada: '+completed+' pruebas Chromium OK; sin llamadas a Supabase.');
  }finally{await browser.close();await new Promise(resolve=>testServer.close(resolve));}
}
run().catch(e=>{console.error(e.stack||e);process.exitCode=1;});
