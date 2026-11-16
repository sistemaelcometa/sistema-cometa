"use client";
import * as React from "react";
import {harvestLabel,storeLabel,tonnes} from "@/lib/cometa-grain";
import type {GrainData,GrainStore} from "@/lib/cometa-grain";

const cropColors=['#98bd7c','#e3c16c','#84b9d3','#bb9acd','#d4967b','#7db8a8'];
const cropKey=(crop:string)=>crop.trim().toLocaleLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g,'');
function cropColor(crop:string){const key=cropKey(crop),known:Record<string,string>={soja:'#98bd7c',maiz:'#e3c16c',trigo:'#d4967b',girasol:'#bb9acd',sorgo:'#84b9d3'};if(known[key])return known[key];let hash=0;for(const letter of key)hash=(hash*31+letter.charCodeAt(0))>>>0;return cropColors[hash%cropColors.length]}

export function CometaStorage({data,canWrite,onEdit,onExtract}:{data:GrainData;canWrite:boolean;onEdit:(store:GrainStore)=>void;onExtract:(store:GrainStore)=>void}){
 return <>{([{kind:'silo',title:'Silos fijos'},{kind:'bag',title:'Silos bolsa'}] as const).map(group=>{
  const stores=data.stores.filter(store=>store.kind===group.kind),ids=new Set(stores.map(store=>store.id));
  const total=data.balances.filter(row=>ids.has(row.store_id)).reduce((sum,row)=>sum+Number(row.tonnes),0);
  return <section className="cometa-storage-group" aria-label={group.title} key={group.kind}><div className="section-title"><h4>{group.title}</h4><strong>{tonnes(total)} almacenadas</strong></div>{stores.length===0?<p className="empty-state">{group.kind==='bag'?'Todavía no hay silos bolsa. Podés crearlos al registrar una cosecha.':'Todavía no hay silos fijos.'}</p>:<div className="cometa-store-grid">{stores.map(store=><GrainStoreCard key={store.id} store={store} data={data} canWrite={canWrite} onEdit={()=>onEdit(store)} onExtract={()=>onExtract(store)}/>)}</div>}</section>;
 })}</>;
}

function GrainStoreCard({store,data,canWrite,onEdit,onExtract}:{store:GrainStore;data:GrainData;canWrite:boolean;onEdit:()=>void;onExtract:()=>void}){
 const clipId=React.useId().replace(/:/g,''),balances=data.balances.filter(row=>row.store_id===store.id&&Number(row.tonnes)>0),total=balances.reduce((sum,row)=>sum+Number(row.tonnes),0);
 const harvests=new Map(data.harvests.map(row=>[row.id,row])),crops=new Map<string,{name:string;tonnes:number}>();
 for(const balance of balances){const name=harvests.get(balance.harvest_id)?.crop||'Cultivo sin especificar',key=cropKey(name),previous=crops.get(key);crops.set(key,{name,tonnes:(previous?.tonnes||0)+Number(balance.tonnes)})}
 const cropsList=Array.from(crops.values()).sort((a,b)=>a.name.localeCompare(b.name,'es'));
 const capacity=Number(store.capacity),percent=Number.isFinite(capacity)&&capacity>0?total/capacity*100:null;
 const label=percent===null?'Sin capacidad':new Intl.NumberFormat('es-AR',{maximumFractionDigits:1}).format(percent)+'%';
 const isBag=store.kind==='bag',shape=isBag?'M42 24 H138 A30 30 0 0 1 138 84 H42 A30 30 0 0 1 42 24Z':'M26 44 L70 16 L114 44 V144 Q70 164 26 144Z';
 const bottom=isBag?84:154,height=isBag?60:110,visibleHeight=percent===null?0:height*Math.min(percent/100,1);
 let filled=0;
 return <article className="panel cometa-store-card"><div className="section-title"><div><small>{store.location} · {isBag?'Silo bolsa':'Silo fijo'}</small><h4>{store.name}</h4></div>{canWrite&&<button className="small-button" onClick={onEdit}>Editar</button>}</div>
  <div className="cometa-store-contents"><div className={'cometa-silo-visual'+(isBag?' is-bag':'')} role="img" aria-label={storeLabel(store)+': '+tonnes(total)+(percent===null?', capacidad sin definir':', '+label+' de capacidad ocupada')}>
   <svg viewBox={isBag?'0 0 180 110':'0 0 140 180'} aria-hidden="true"><defs><clipPath id={clipId}><path d={shape}/></clipPath></defs><path d={shape} fill="#eef3f4"/>
    <g clipPath={'url(#'+clipId+')'}>{cropsList.map(crop=>{const segment=total?crop.tonnes/total*visibleHeight:0;filled+=segment;return <rect key={crop.name} x={isBag?0:26} y={bottom-filled} width={isBag?180:88} height={segment} fill={cropColor(crop.name)}/>})}</g>
    <path d={shape} fill="none" stroke={percent!==null&&percent>100?'#b94b4b':'#7d97a4'} strokeWidth="2"/>{isBag?<path d="M42 25 Q22 54 42 83 M138 25 Q158 54 138 83" fill="none" stroke="#7d97a4" strokeWidth="1.5"/>:<><path d="M26 44 H114 M26 75 H114 M26 106 H114 M26 135 H114" fill="none" stroke="#7d97a4" opacity=".45"/><path d="M37 149 V170 M103 149 V170" stroke="#7d97a4" strokeWidth="3"/></>}
   </svg><strong className={percent===null?'is-unknown':''}>{label}</strong>
  </div><div className="cometa-store-summary"><strong className="cometa-stock-amount">{tonnes(total)}</strong><small>{percent===null?'Capacidad sin definir':'Capacidad: '+tonnes(capacity)}</small>{percent!==null&&percent>100&&<small className="cometa-expense">La cantidad supera la capacidad registrada.</small>}{!cropsList.length?<span className="cometa-empty-stock">Sin existencias.</span>:<ul className="cometa-crop-list">{cropsList.map(crop=><li key={crop.name}><span><i style={{background:cropColor(crop.name)}} aria-hidden="true"/>{crop.name}</span><strong>{tonnes(crop.tonnes)}</strong></li>)}</ul>}</div></div>
  {balances.length>0&&<details className="cometa-origin-details"><summary>Origen de la mercadería ({balances.length} {balances.length===1?'partida':'partidas'})</summary><div className="cometa-stock-list">{balances.map(row=><div key={row.harvest_id}><span>{harvestLabel(harvests.get(row.harvest_id))}<strong>{tonnes(row.tonnes)}</strong></span></div>)}</div></details>}
  {canWrite&&<button className="secondary-button cometa-extract-button" disabled={total<=0} onClick={onExtract}>Extraer mercadería</button>}
 </article>;
}
