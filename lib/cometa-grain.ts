export type GrainField={id:string;name:string;hectares?:number|null;deleted_at?:string|null};
export type GrainStore={id:string;location:string;name:string;kind:'silo'|'bag';capacity:number|null;bag_number?:number|null;archived?:boolean};
export type Harvest={id:string;field_id:string;field_name:string;field_hectares?:number|null;harvest_date:string;campaign:string;season?:'fina'|'gruesa'|null;crop:string;tonnes:number;voided:boolean};
export type GrainEvent={id:string;operation_id:string;harvest_id:string;event_date:string;kind:'deposit'|'direct_sale'|'sale'|'transfer';source_id:string|null;destination_id:string|null;tonnes:number;recipient:string;reference:string;voided_at:string|null;request?:{batch_exit?:boolean;stock_clear?:boolean}|null;sequence?:number;created_at?:string};
export type GrainData={fields:GrainField[];stores:GrainStore[];harvests:Harvest[];balances:{harvest_id:string;store_id:string;tonnes:number}[];events:GrainEvent[]};
export const emptyGrain:GrainData={fields:[],stores:[],harvests:[],balances:[],events:[]};
export function isStoreArchived(store:GrainStore,data:GrainData){
 if(store.kind!=='bag')return false;
 if(store.archived!==undefined)return store.archived;
 return !data.balances.some(row=>row.store_id===store.id&&Number(row.tonnes)>0)&&data.events.some(row=>row.destination_id===store.id&&!row.voided_at);
}
export const availableGrainStores=(data:GrainData)=>data.stores.filter(store=>!isStoreArchived(store,data));
export function parseTonnes(value:string){
 const text=value.trim().replace(',','.');
 if(!/^\d+(?:\.\d{1,3})?$/.test(text))return null;
 const amount=Number(text);return Number.isFinite(amount)&&amount>0&&amount<1e11?amount:null;
}
export const tonnes=(value:number)=>new Intl.NumberFormat('es-AR',{maximumFractionDigits:3}).format(Number(value||0))+' t';
export const hectaresLabel=(value?:number|null)=>Number(value)>0?new Intl.NumberFormat('es-AR',{maximumFractionDigits:3}).format(Number(value))+' ha':'Sin superficie';
export function harvestYield(amount:number,area?:number|null){
 return Number.isFinite(Number(amount))&&Number.isFinite(Number(area))&&Number(area)>0?Number(amount)/Number(area):null;
}
export const yieldLabel=(amount:number,area?:number|null)=>{const value=harvestYield(amount,area);return value===null?'—':new Intl.NumberFormat('es-AR',{maximumFractionDigits:3}).format(value)+' t/ha'};
export const bagNumberLabel=(store:GrainStore)=>store.kind==='bag'&&store.bag_number?'SB-'+String(store.bag_number).padStart(4,'0'):'';
export const storeLabel=(store?:GrainStore)=>store?[store.location,store.name,bagNumberLabel(store)].filter(Boolean).join(' · '):'Venta directa';
export const harvestLabel=(harvest?:Harvest)=>harvest?harvest.field_name+' · '+harvest.crop+' · '+harvest.campaign+(harvest.season?' · '+(harvest.season==='fina'?'Fina':'Gruesa'):''):'';
export function grainEventName(event:GrainEvent){
 return event.request?.stock_clear?'Liquidación de stock':({deposit:'Ingreso de cosecha',direct_sale:'Venta directa desde cosecha',sale:'Extracción de mercadería',transfer:'Traslado'})[event.kind];
}
export function groupGrainEvents(events:GrainEvent[]){
 const groups=new Map<string,{id:string;events:GrainEvent[]}>();
 for(const event of events){const key=event.request?.batch_exit?'batch:'+event.operation_id:'event:'+event.id;const group=groups.get(key);if(group)group.events.push(event);else groups.set(key,{id:key,events:[event]})}
 return Array.from(groups.values());
}
// La bolsa se llena por sus entradas reales. Las extracciones no reducen la
// referencia; nuevas cargas pueden completarla hasta un contenido mayor.
export function bagReferenceTonnes(storeId:string,events:GrainEvent[]){
 const timeline=events.map((event,index)=>({event,index})).filter(({event})=>!event.voided_at&&(event.source_id===storeId||event.destination_id===storeId)).sort((a,b)=>a.event.event_date.localeCompare(b.event.event_date)||(a.event.sequence!=null&&b.event.sequence!=null?Number(a.event.sequence)-Number(b.event.sequence):String(a.event.created_at||'').localeCompare(String(b.event.created_at||''))||b.index-a.index));
 let stockKg=0,peakKg=0;
 for(const {event} of timeline){const quantity=Math.round(Number(event.tonnes)*1000);stockKg+=(event.destination_id===storeId?quantity:0)-(event.source_id===storeId?quantity:0);peakKg=Math.max(peakKg,stockKg)}
 return peakKg/1000;
}
export function harvestCropTotals(data:GrainData){
 const normalize=(value:string)=>value.trim().toLocaleLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g,'');
 const totals=[{key:'maiz',name:'Maíz',harvestedKg:0,storedKg:0},{key:'soja',name:'Soja',harvestedKg:0,storedKg:0},{key:'trigo',name:'Trigo',harvestedKg:0,storedKg:0}];
 const harvests=new Map(data.harvests.filter(row=>!row.voided).map(row=>[row.id,row]));
 for(const harvest of harvests.values()){const item=totals.find(item=>item.key===normalize(harvest.crop));if(item)item.harvestedKg+=Math.round(Number(harvest.tonnes)*1000)}
 for(const balance of data.balances){const harvest=harvests.get(balance.harvest_id),item=harvest&&totals.find(item=>item.key===normalize(harvest.crop));if(item)item.storedKg+=Math.round(Number(balance.tonnes)*1000)}
 return totals.map(({key,name,harvestedKg,storedKg})=>({key,name,harvested:harvestedKg/1000,stored:storedKg/1000}));
}
export function storageCropTotals(data:GrainData){
 const normalize=(value:string)=>value.trim().toLocaleLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g,'');
 const totals=[{key:'maiz',name:'Maíz',fixedKg:0,bagKg:0},{key:'soja',name:'Soja',fixedKg:0,bagKg:0},{key:'trigo',name:'Trigo',fixedKg:0,bagKg:0}];
 const harvests=new Map(data.harvests.filter(row=>!row.voided).map(row=>[row.id,row])),stores=new Map(data.stores.map(row=>[row.id,row]));
 for(const balance of data.balances){const harvest=harvests.get(balance.harvest_id),store=stores.get(balance.store_id),item=harvest&&totals.find(item=>item.key===normalize(harvest.crop));if(!item||!store)continue;const amount=Math.round(Number(balance.tonnes)*1000);if(store.kind==='silo')item.fixedKg+=amount;else item.bagKg+=amount}
 return totals.map(({key,name,fixedKg,bagKg})=>({key,name,stored:(fixedKg+bagKg)/1000,fixed:fixedKg/1000,bags:bagKg/1000}));
}
