import { DOMImplementation, DOMParser, XMLSerializer } from '@xmldom/xmldom';
import './bootstrap.js';

import '@plantuml/core/themes.js';
import { renderToString } from '@plantuml/core';

globalThis.window = globalThis;
globalThis.DOMParser = DOMParser;
globalThis.XMLSerializer = XMLSerializer;
globalThis.console = {log(){}, warn(){}, error(){}};
const doc = new DOMImplementation().createDocument(null, 'root', null);
const make = doc.createElementNS.bind(doc);
doc.createElementNS = (ns, name) => {
 const el = make(ns, name); el.style = {};
 el.getBBox = () => {const m=nativeMeasure(el.textContent,el.getAttribute('font-family')||'sans-serif',Number(el.getAttribute('font-size'))||14,'normal'); return {width:m[0],height:m[1]+m[2],x:0,y:-m[1]};};
 return el;
};
doc.createElement = name => name === 'canvas' ? {getContext:()=>({font:'14px sans-serif',measureText(text){const m = /([0-9.]+)px\s+(.*)/.exec(this.font); const r=nativeMeasure(text,m?.[2]||'sans-serif',Number(m?.[1])||14,this.font); return {width:r[0],actualBoundingBoxAscent:r[1],actualBoundingBoxDescent:r[2],fontBoundingBoxAscent:r[1],fontBoundingBoxDescent:r[2]};}})} : doc.createElementNS(null,name);
doc.body=doc.documentElement; globalThis.document=doc;
let timers = [], id = 0;
globalThis.setTimeout=(fn,ms)=>{timers.push({fn,ms,id:++id});return id;};
globalThis.clearTimeout=id=>{timers=timers.filter(t=>t.id!==id);};
globalThis.atob=s=>String.fromCharCode(...nativeBase64(s));
globalThis.performance={now:()=>Date.now()};
globalThis.PLANTUML_STDLIB_LOADER=(name,ok,fail)=>{fail('External libraries are disabled');return true;};
globalThis.PLANTUML_FILE_LOADER=(name,ok,fail)=>{fail('File includes are disabled');return true;};
// AppKit's SVG importer does not understand #RRGGBBAA. Preserve alpha through
// ordinary SVG opacity attributes, especially transparent sequence lifelines.
function nativeSVG(svg) {
 const document = new DOMParser().parseFromString(svg, 'image/svg+xml');
 for (const element of Array.from(document.getElementsByTagName('*'))) {
  for (const name of ['fill', 'stroke']) {
   const match = /^#([0-9a-f]{6})([0-9a-f]{2})$/i.exec(element.getAttribute(name));
   if (!match) continue;
   const alpha = parseInt(match[2], 16) / 255;
   element.setAttribute(name, alpha === 0 ? 'none' : '#' + match[1]);
   if (alpha > 0 && alpha < 1) {
    const opacity = element.getAttribute(name + '-opacity');
    element.setAttribute(name + '-opacity', String(alpha * (opacity ? Number(opacity) : 1)));
   }
  }
 }
 return new XMLSerializer().serializeToString(document);
}
globalThis.startRender=(source,dark)=>{globalThis.result=null;globalThis.failure=null;renderToString(source.split('\n').flatMap(line => /^\s*@startuml\b/.test(line) ? [line, '!pragma layout smetana'] : [line]),svg=>{result=nativeSVG(svg);},message=>{failure=String(message);},{dark,maxSvgSize:4096});};
globalThis.pump=()=>{timers.sort((a,b)=>a.ms-b.ms);const t=timers.shift();if(t)t.fn();return !!t;};
