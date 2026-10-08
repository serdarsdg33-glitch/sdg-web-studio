'use strict';
// Publish only static website files. Server code and SQL never enter the publish folder.
const fs=require('node:fs'),path=require('node:path');
const root=process.cwd(),destination=path.join(root,'seray-public');
const excluded=new Set(['netlify','supabase','node_modules','seray-public']);
const publicTypes=new Set(['.html','.css','.js','.webp','.png','.jpg','.jpeg','.svg','.ico','.avif','.gif','.woff','.woff2','.ttf','.mp4','.webm']);
// Stop the deployment before replacing a working site with empty or truncated files.
const requiredFiles=['serdar-web-studio-standalone.html','seray-panel.js','seray-panel.css'];
for(const file of requiredFiles){
 const source=path.join(root,file);
 if(!fs.existsSync(source)||fs.statSync(source).size<100)throw new Error('Website file is missing, empty or incomplete: '+file);
}
const html=fs.readFileSync(path.join(root,requiredFiles[0]),'utf8');
if(!/<!doctype html>/i.test(html)||!/<\/html>\s*$/i.test(html)||!html.includes('id="account"'))throw new Error('Website HTML is incomplete. Restore the full downloaded file.');
new (require('node:vm').Script)(fs.readFileSync(path.join(root,'seray-panel.js'),'utf8'),{filename:'seray-panel.js'});
fs.rmSync(destination,{recursive:true,force:true});fs.mkdirSync(destination,{recursive:true});
function copy(folder,relative=''){
 for(const entry of fs.readdirSync(folder,{withFileTypes:true})){
  if(entry.name.startsWith('.')||excluded.has(entry.name)||entry.isSymbolicLink())continue;
  const source=path.join(folder,entry.name),sub=path.join(relative,entry.name);
  if(entry.isDirectory())copy(source,sub);
  else if(entry.isFile()&&publicTypes.has(path.extname(entry.name).toLowerCase())){const target=path.join(destination,sub);fs.mkdirSync(path.dirname(target),{recursive:true});fs.copyFileSync(source,target);}
 }
}
copy(root);
for(const file of requiredFiles)if(!fs.existsSync(path.join(destination,file))||fs.statSync(path.join(destination,file)).size!==fs.statSync(path.join(root,file)).size)throw new Error('Published website file failed validation: '+file);
console.log('SERAY static files prepared; backend and setup files excluded.');
