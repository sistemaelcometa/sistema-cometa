export type GrainField={id:string;name:string;hectares?:number|null;deleted_at?:string|null};
export type GrainStore={id:string;location:string;name:string;kind:'silo'|'bag';capacity:number|null};
export type Harvest={id:string;field_id:string;field_name:string;field_hectares?:number|null;harvest_date:string;campaign:string;season?:'fina'|'gruesa'|null;crop:string;tonnes:number;voided:boolean};
export type GrainEvent={id:string;operation_id:string;harvest_id:string;event_date:string;kind:'deposit'|'direct_sale'|'sale'|'transfer';source_id:string|null;destination_id:string|null;tonnes:number;recipient:string;reference:string;voided_at:string|null;request?:{batch_exit?:boolean}|null};
export type GrainData={fields:GrainField[];stores:GrainStore[];harvests:Harvest[];balances:{harvest_id:string;store_id:string;tonnes:number}[];events:GrainEvent[]};
export const emptyGrain:GrainData={fields:[],stores:[],harvests:[],balances:[],events:[]};
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
export const storeLabel=(store?:GrainStore)=>store?store.location+' · '+store.name:'Venta directa';
export const harvestLabel=(harvest?:Harvest)=>harvest?harvest.field_name+' · '+harvest.crop+' · '+harvest.campaign+(harvest.season?' · '+(harvest.season==='fina'?'Fina':'Gruesa'):''):'';
export function groupGrainEvents(events:GrainEvent[]){
 const groups=new Map<string,{id:string;events:GrainEvent[]}>();
 for(const event of events){const key=event.request?.batch_exit?'batch:'+event.operation_id:'event:'+event.id;const group=groups.get(key);if(group)group.events.push(event);else groups.set(key,{id:key,events:[event]})}
 return Array.from(groups.values());
}
