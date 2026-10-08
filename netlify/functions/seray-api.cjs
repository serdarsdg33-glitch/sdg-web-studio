'use strict';
// Node 22+, built-in fetch. Credentials stay in Netlify environment variables.
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ownFields='id,service_id,service_name,quantity,link,charge_minor,refunded_minor,status,created_at';
const fail=(code,status=400)=>Object.assign(new Error(code),{status});
const int=(v,min,max)=>{if(!Number.isSafeInteger(v)||v<min||v>max)throw fail('INVALID_NUMBER');return v;};
const str=(v,max,min=1)=>{if(typeof v!=='string'||v.trim().length<min||v.length>max)throw fail('INVALID_TEXT');return v.trim();};
const passwordValue=v=>{if(typeof v!=='string'||v.length<12||v.length>128)throw fail('INVALID_PASSWORD');return v;};
const uuid=v=>{if(!UUID.test(v||''))throw fail('INVALID_ID');return v;};
function settings(){
 const site=process.env.SITE_URL||process.env.URL||'';
 let origin='';try{origin=new URL(site).origin;}catch(_){}
 return {url:(process.env.SUPABASE_URL||'').replace(/\/$/,''),key:process.env.SUPABASE_PUBLISHABLE_KEY||process.env.SUPABASE_ANON_KEY||'',secret:process.env.SUPABASE_SECRET_KEY||process.env.SUPABASE_SERVICE_ROLE_KEY||'',origin,
 admins:(process.env.ADMIN_EMAILS||'').split(',').map(x=>x.trim().toLowerCase()).filter(Boolean),supplier:process.env.SMM_API_URL||'https://anabayiniz.com/api/v2',supplierKey:process.env.SMM_API_KEY||'',payment:process.env.MANUAL_PAYMENT_INSTRUCTIONS||''};
}
async function request(url,options){
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),12000);
 try{
  const r=await fetch(url,{...options,signal:controller.signal});let data=null;
  if(typeof r.text==='function'){
   const raw=await r.text();if(raw){try{data=JSON.parse(raw);}catch(_){throw fail('UPSTREAM_UNAVAILABLE',502);}}
  }else if(typeof r.json==='function'){
   try{data=await r.json();}catch(_){throw fail('UPSTREAM_UNAVAILABLE',502);}
  }
  return {ok:r.ok,status:r.status,data};
 }
 catch(e){if(e.status)throw e;throw fail('UPSTREAM_UNAVAILABLE',502);}finally{clearTimeout(timer);}
}
function auth(c,path,body,token){return request(c.url+'/auth/v1/'+path,{method:body===undefined?'GET':'POST',headers:{apikey:c.key,'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});}
async function db(c,path,method='GET',body){
 const headers={apikey:c.secret,'Content-Type':'application/json',Prefer:'return=representation'};
 if(c.secret.startsWith('eyJ'))headers.Authorization='Bearer '+c.secret;
 const r=await request(c.url+'/rest/v1/'+path,{method,headers,...(body===undefined?{}:{body:JSON.stringify(body)})});
 if(!r.ok){const known=['INSUFFICIENT_BALANCE','PRICE_CHANGED','SERVICE_UNAVAILABLE','INVALID_QUANTITY','REQUEST_CONFLICT','ACCOUNT_BLOCKED','ACCOUNT_MISSING','NOT_FOUND','INVALID_UPDATE','ORDER_FINAL','INVALID_REFUND','INVALID_REQUEST'];throw fail(known.find(x=>(r.data?.message||'').includes(x))||'DATABASE_UNAVAILABLE',r.status>=500?503:400);}
 return r.data;
}
const rpc=(c,name,args)=>db(c,'rpc/'+name,'POST',args);
const cookie=(name,value,age)=>{
 const expires=new Date(age>0?Date.now()+(age*1000):0).toUTCString();
 return `${name}=${encodeURIComponent(value)}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${age}; Expires=${expires}`;
};
function setSession(headers,s){
 if(typeof s.access_token!=='string'||typeof s.refresh_token!=='string')throw fail('SESSION_INVALID',401);
 headers['Set-Cookie']=[cookie('seray_access',s.access_token,Math.min(s.expires_in||3600,7200)),cookie('seray_refresh',s.refresh_token,2592000)];
}
function cookies(event){const out={};const raw=event.headers.cookie||event.headers.Cookie||'';for(const p of raw.split(';')){const at=p.indexOf('=');if(at>0){try{out[p.slice(0,at).trim()]=decodeURIComponent(p.slice(at+1));}catch(_){}}}return out;}
async function user(c,event,headers){
 const ck=cookies(event);let token=ck.seray_access,r=token?await auth(c,'user',undefined,token):null;
 if(!r?.ok&&ck.seray_refresh){const renew=await auth(c,'token?grant_type=refresh_token',{refresh_token:ck.seray_refresh});if(renew.ok){setSession(headers,renew.data);token=renew.data.access_token;r=await auth(c,'user',undefined,token);}}
 if(!r?.ok||!UUID.test(r.data?.id||''))throw fail('LOGIN_REQUIRED',401);
 const u=r.data;if(!u.email_confirmed_at)throw fail('VERIFY_EMAIL',403);
 await rpc(c,'seray_ensure_user',{p_user:u.id,p_email:u.email||''});
 const p=await db(c,'seray_profiles?user_id=eq.'+u.id+'&select=blocked');if(p[0]?.blocked)throw fail('ACCOUNT_BLOCKED',403);
 return {...u,token,isAdmin:Boolean(u.email_confirmed_at&&c.admins.includes((u.email||'').toLowerCase()))};
}
const admin=u=>{if(!u.isAdmin)throw fail('ADMIN_REQUIRED',403);};
const one=rows=>{if(!rows?.[0])throw fail('NOT_FOUND',404);return rows[0];};
async function dashboard(c,u){
 const root='?user_id=eq.'+u.id;
 const [wallet,orders,topups,tickets,transactions]=await Promise.all([
  db(c,'seray_wallets'+root+'&select=balance_minor,currency'),db(c,'seray_orders'+root+'&select='+ownFields+'&order=created_at.desc&limit=100'),
  db(c,'seray_topups'+root+'&select=id,amount_minor,reference,status,created_at&order=created_at.desc&limit=100'),
  db(c,'seray_tickets'+root+'&select=id,subject,message,reply,status,created_at&order=created_at.desc&limit=100'),
  db(c,'seray_transactions'+root+'&select=id,amount_minor,kind,order_id,topup_id,created_at&order=created_at.desc&limit=100')]);
 return {user:{id:u.id,email:u.email,isAdmin:u.isAdmin},wallet:one(wallet),orders,topups,tickets,transactions,paymentInstructions:c.payment};
}
function validLink(link,hosts){
 try{const u=new URL(link);return ['https:','http:'].includes(u.protocol)&&!u.username&&!u.password&&!u.port&&u.pathname.replace(/\//g,'').length>0&&hosts.some(h=>u.hostname===h||u.hostname.endsWith('.'+h));}catch(_){return false;}
}
async function supplier(c,body){
 if(!c.supplierKey)throw fail('PROVIDER_NOT_CONFIGURED',503);
 let url;try{url=new URL(c.supplier);}catch(_){throw fail('PROVIDER_NOT_CONFIGURED',503);}
 if(url.protocol!=='https:')throw fail('PROVIDER_NOT_CONFIGURED',503);
 const r=await request(url.toString(),{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({key:c.supplierKey,...body}).toString()});
 if(!r.ok)throw fail('PROVIDER_UNAVAILABLE',502);return r.data;
}
async function dispatch(c,id){
 if(!c.supplierKey)throw fail('PROVIDER_NOT_CONFIGURED',503);
 const claimed=await rpc(c,'seray_claim_provider_order',{p_id:id});
 if(!claimed?.id)throw fail('ORDER_ALREADY_SENT');
 const payload={action:'add',service:String(claimed.provider_service_id),link:claimed.link,quantity:String(claimed.quantity)};
 if(claimed.provider_type==='Custom Comments'){payload.comments=claimed.details.comments;delete payload.quantity;}
 try{
  const result=await supplier(c,payload);
  if(!Number.isSafeInteger(Number(result.order))||Number(result.order)<=0)throw fail('PROVIDER_REVIEW_REQUIRED');
  await db(c,'seray_orders?id=eq.'+id,'PATCH',{provider_id:Number(result.order),provider_state:'submitted',updated_at:new Date().toISOString()});
  return {sent:true};
 }catch(_){
  // A timeout may still create a supplier order. Never retry or refund automatically.
  await db(c,'seray_orders?id=eq.'+id,'PATCH',{provider_state:'unknown',status:'needs_review',updated_at:new Date().toISOString()});
  throw fail('PROVIDER_REVIEW_REQUIRED',409);
 }
}
async function syncOrder(c,id){
 const o=one(await db(c,'seray_orders?id=eq.'+id));
 if(o.provider_state!=='submitted'||!o.provider_id)throw fail('ORDER_NOT_SENT');
 if(['completed','partial','cancelled'].includes(o.status))return {status:o.status};
 const r=await supplier(c,{action:'status',order:String(o.provider_id)});
 const statuses={Pending:'processing','In progress':'processing',Processing:'processing',Completed:'completed',Partial:'partial',Canceled:'cancelled',Cancelled:'cancelled'};
 const status=statuses[r.status];if(!status)throw fail('PROVIDER_REVIEW_REQUIRED',409);
 let refund=Number(o.refunded_minor);
 if(status==='cancelled')refund=Number(o.charge_minor);
 if(status==='partial'){
  const remains=Number(r.remains);if(!Number.isSafeInteger(remains)||remains<0||remains>o.quantity)throw fail('PROVIDER_REVIEW_REQUIRED',409);
  refund=Math.max(refund,Math.floor(Number(o.charge_minor)*remains/o.quantity));
 }
 await rpc(c,'seray_update_order',{p_id:id,p_status:status,p_refund_total:refund});return {status};
}
exports.handler=async event=>{
 const c=settings(),headers={'Content-Type':'application/json; charset=utf-8','Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff'};
 const respond=(status,body)=>({statusCode:status,headers:{...headers,...(!headers['Set-Cookie']?{}:{})},...(headers['Set-Cookie']?{multiValueHeaders:{'Set-Cookie':headers['Set-Cookie']}}:{}),body:JSON.stringify(body)});
 // Cookies belong in multiValueHeaders; never combine them into a single header.
 const response=(status,body)=>{const r=respond(status,body);delete r.headers['Set-Cookie'];return r;};
 try{
  const ready=Boolean(c.url&&c.key&&c.secret&&c.origin);
  if(c.url.includes('zpwxvngrowhqquwpovuf'))throw fail('SEPARATE_PROJECT_REQUIRED',503);
  if(event.httpMethod==='GET')return response(200,{ready,currency:'USD'});
  if(event.httpMethod!=='POST')return response(405,{error:'METHOD_NOT_ALLOWED'});
  if(!ready)return response(503,{error:'SETUP_REQUIRED'});
  if(event.headers.origin!==c.origin)throw fail('ORIGIN_REJECTED',403);
  if(!(event.headers['content-type']||'').toLowerCase().startsWith('application/json'))throw fail('JSON_REQUIRED',415);
  if(event.isBase64Encoded||typeof event.body!=='string'||Buffer.byteLength(event.body)>20000)throw fail('REQUEST_TOO_LARGE',413);
  let b;try{b=JSON.parse(event.body);}catch(_){throw fail('INVALID_JSON');}if(!b||typeof b!=='object'||Array.isArray(b))throw fail('INVALID_JSON');
  let result;
  if(['signup','login','recover','session'].includes(b.action)){
   if(b.action==='session'){
    const access=str(b.access_token,12000),refresh=str(b.refresh_token,1000),r=await auth(c,'user',undefined,access);
    if(!r.ok||!r.data?.email_confirmed_at)throw fail('SESSION_INVALID',401);
    setSession(headers,{access_token:access,refresh_token:refresh,expires_in:3600});result={ok:true};
   }else{
    const email=str(b.email,254).toLowerCase();if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))throw fail('INVALID_EMAIL');
    const redirect=encodeURIComponent(c.origin+'/#account');
    if(b.action==='recover'){await auth(c,'recover?redirect_to='+redirect,{email});result={ok:true};}
    else{
     const password=passwordValue(b.password);
     if(b.action==='login'){
      const r=await auth(c,'token?grant_type=password',{email,password});if(!r.ok)throw fail('LOGIN_FAILED',401);
      const verified=await auth(c,'user',undefined,r.data.access_token);if(!verified.ok||!verified.data.email_confirmed_at)throw fail('VERIFY_EMAIL',403);
      setSession(headers,r.data);result={ok:true};
     }else{
      const r=await auth(c,'signup?redirect_to='+redirect,{email,password});if(!r.ok)throw fail('SIGNUP_FAILED');
      // Require email verification even if project confirmation has been disabled.
      if(r.data.access_token&&r.data.user?.email_confirmed_at)setSession(headers,r.data);
      result={ok:true,checkEmail:!r.data.access_token};
     }
    }
   }
   return response(200,result);
  }
  if(b.action==='logout'){
   const ck=cookies(event);if(ck.seray_access)try{await auth(c,'logout',{},ck.seray_access);}catch(_){}
   headers['Set-Cookie']=[cookie('seray_access','',0),cookie('seray_refresh','',0)];return response(200,{ok:true});
  }
  if(b.action==='catalog'){
   result=await db(c,'seray_services?enabled=eq.true&select=id,name,rate_minor,pricing_unit,min_quantity,max_quantity&order=id');return response(200,{services:result});
  }
  const u=await user(c,event,headers);
  switch(b.action){
   case 'dashboard':result=await dashboard(c,u);break;
   case 'password':{
    const password=passwordValue(b.password);
    const r=await request(c.url+'/auth/v1/user',{method:'PUT',headers:{apikey:c.key,Authorization:'Bearer '+u.token,'Content-Type':'application/json'},body:JSON.stringify({password})});
    if(!r.ok)throw fail('PASSWORD_FAILED');result={ok:true};break;
   }
   case 'order':{
    const id=str(b.serviceId,100),quantity=int(b.quantity,1,1000000),link=str(b.link,2000),key=uuid(b.requestKey),expected=int(b.expectedCharge,1,100000000000000);
    const s=one(await db(c,'seray_services?id=eq.'+encodeURIComponent(id)));
    if(!validLink(link,s.hosts))throw fail('INVALID_LINK');
    const details={comments:typeof b.comments==='string'?str(b.comments,8000,0):'',country:typeof b.country==='string'?str(b.country,2,0):'',posts:b.posts?int(b.posts,1,1000):null,notes:typeof b.notes==='string'?str(b.notes,8000,0):''};
    const category=id.split(':')[1];
    if((id.endsWith(':domestic')||['likesLocal','likesCountry','viewsCountry','retweetLocal'].includes(category))&&!/^[A-Z]{2}$/.test(details.country))throw fail('INVALID_COUNTRY');
    if(['comments','chat'].includes(category)&&!details.comments.trim())throw fail('COMMENTS_REQUIRED');
    if(category==='auto'&&!details.posts)throw fail('INVALID_QUANTITY');
    if(s.provider_type==='Custom Comments'&&details.comments.split('\n').map(x=>x.trim()).filter(Boolean).length!==quantity)throw fail('COMMENTS_COUNT');
    result=await rpc(c,'seray_place_order',{p_user:u.id,p_key:key,p_service:id,p_quantity:quantity,p_link:link,p_details:details,p_expected:expected});
    // Automatic supplier dispatch is deliberately an explicit admin action in this version.
    result={id:result.id,status:result.status,charge_minor:result.charge_minor};break;
   }
   case 'topup':{
    if(!c.payment)throw fail('PAYMENT_NOT_CONFIGURED',503);
    const amount=int(b.amountMinor,100,1000000),reference=str(b.reference,150,3);
    const prior=await db(c,'seray_topups?user_id=eq.'+u.id+'&reference=eq.'+encodeURIComponent(reference));
    if(prior[0]){if(Number(prior[0].amount_minor)!==amount)throw fail('REQUEST_CONFLICT');result={ok:true};break;}
    await db(c,'seray_topups','POST',{user_id:u.id,amount_minor:amount,reference});result={ok:true};break;
   }
   case 'ticket':await db(c,'seray_tickets','POST',{user_id:u.id,subject:str(b.subject,120,3),message:str(b.message,4000,5)});result={ok:true};break;
   case 'admin':{
    admin(u);const [services,orders,topups,tickets,users]=await Promise.all([
     db(c,'seray_services?order=id'),db(c,'seray_orders?order=created_at.desc&limit=100'),db(c,'seray_topups?status=eq.pending&order=created_at&limit=100'),db(c,'seray_tickets?status=neq.closed&order=created_at.desc&limit=100'),db(c,'seray_profiles?order=created_at.desc&limit=100')]);
    result={services,orders,topups,tickets,users,providerReady:Boolean(c.supplierKey)};break;
   }
   case 'price':{
    admin(u);const id=str(b.id,100),enabled=b.enabled===true,rate=b.rateMinor===null?null:int(b.rateMinor,1,100000000),unit=int(b.unit,1,1000);
    if(![1,1000].includes(unit)||enabled&&rate===null)throw fail('INVALID_PRICE');
    const min=int(b.min,1,1000000),max=int(b.max,min,1000000),type=b.providerType||'manual';
    if(!['manual','Default','Custom Comments'].includes(type))throw fail('INVALID_PROVIDER');
    // Only single, one-time services map to supported supplier order types.
    const serviceKey=id.split(':')[1];
    if(type!=='manual'&&['auto','monthly','poll','storyLink','live','space','watchHours'].includes(serviceKey))throw fail('MANUAL_SERVICE_REQUIRED');
    if(type==='Custom Comments'&&!['comments','chat'].includes(serviceKey))throw fail('INVALID_PROVIDER');
    const providerId=type==='manual'?null:int(b.providerId,1,2147483647);
    result=await db(c,'seray_services?id=eq.'+encodeURIComponent(id),'PATCH',{rate_minor:rate,pricing_unit:unit,min_quantity:min,max_quantity:max,enabled,provider_type:type,provider_service_id:providerId});one(result);result={ok:true};break;
   }
   case 'approve':admin(u);await rpc(c,'seray_decide_topup',{p_id:uuid(b.id),p_approve:b.approve===true});result={ok:true};break;
   case 'orderStatus':{
    admin(u);const o=one(await db(c,'seray_orders?id=eq.'+uuid(b.id)));
    if(['submitting','unknown'].includes(o.provider_state))throw fail('PROVIDER_REVIEW_REQUIRED',409);
    if(o.provider_state==='submitted')throw fail('USE_PROVIDER_SYNC');
    await rpc(c,'seray_update_order',{p_id:o.id,p_status:b.status,p_refund_total:int(b.refundMinor,0,Number(o.charge_minor))});result={ok:true};break;
   }
   case 'reply':admin(u);one(await db(c,'seray_tickets?id=eq.'+uuid(b.id),'PATCH',{reply:str(b.reply,4000),status:'answered'}));result={ok:true};break;
   case 'block':admin(u);if(uuid(b.id)===u.id)throw fail('CANNOT_BLOCK_SELF');one(await db(c,'seray_profiles?user_id=eq.'+b.id,'PATCH',{blocked:b.blocked===true}));result={ok:true};break;
   case 'providerCatalog':admin(u);result=await supplier(c,{action:'services'});if(!Array.isArray(result))throw fail('PROVIDER_UNAVAILABLE',502);result={services:result};break;
   case 'dispatch':admin(u);result=await dispatch(c,uuid(b.id));break;
   case 'sync':admin(u);result=await syncOrder(c,uuid(b.id));break;
   case 'reconcile':{
    admin(u);const o=one(await db(c,'seray_orders?id=eq.'+uuid(b.id)));
    if(!['unknown','submitting'].includes(o.provider_state))throw fail('INVALID_UPDATE');
    // Only a confirmed supplier-side failure may release this hold for manual fulfilment.
    if(b.confirmedNotReceived===true){
     one(await db(c,'seray_orders?id=eq.'+o.id+'&provider_state=eq.'+o.provider_state,'PATCH',{provider_state:'none',provider_type:'manual',provider_service_id:null,status:'queued'}));result={ok:true};break;
    }
    // Admin confirms the supplier panel was checked before recording an actual order ID.
    const providerId=int(b.providerId,1,Number.MAX_SAFE_INTEGER);
    one(await db(c,'seray_orders?id=eq.'+o.id+'&provider_state=eq.'+o.provider_state,'PATCH',{provider_id:providerId,provider_state:'submitted',status:'processing'}));result={ok:true};break;
   }
   default:throw fail('UNKNOWN_ACTION');
  }
  return response(200,result);
 }catch(e){return response(e.status||500,{error:e.status?e.message:'SERVER_ERROR'});}
};
