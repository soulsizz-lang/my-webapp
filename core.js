/* UI-independent classroom rules; demo storage never participates in live classes. */
window.Career = (()=>{
 const fields=['now','tech','future','evidence','prepare','source'];
 const uid=()=>crypto.randomUUID();
 const jobOK=n=>Number.isInteger(+n)&&+n>=1&&+n<=200;
 const nonempty=s=>typeof s==='string'&&s.trim().length>0;
 const ranks=(c,sid)=>{const counts={};c.votes.filter(v=>v.to===sid&&!v.hidden).forEach(v=>counts[v.job]=(counts[v.job]||0)+1);return Object.entries(counts).map(([job,count])=>({job:+job,count})).sort((a,b)=>b.count-a.count||a.job-b.job)};
 const candidates=(c,sid)=>{const s=c.students.find(s=>s.id===sid);const r=ranks(c,sid).filter(r=>r.job!==+s.choice?.job);return r.length?r.filter(x=>x.count===r[0].count).map(x=>x.job):Array.from({length:200},(_,i)=>i+1).filter(id=>id!==+s.choice?.job)};
 const targets=(c,sid)=>{const ids=c.students.map(s=>s.id),i=ids.indexOf(sid),n=Math.min(+c.quota||5,ids.length-1);return Array.from({length:n},(_,j)=>ids[(i+j+1)%ids.length])};
 function validateResearch(r,submit=false){if(!Array.isArray(r)||r.length!==2||r.some(x=>!jobOK(x.job))||r[0].job===r[1].job)throw Error('서로 다른 두 직업을 선택해 주세요.');for(const x of r)for(const f of fields){if(typeof x[f]!=='string'||x[f].length>1000)throw Error('항목별로 1,000자 이내로 작성해 주세요.');if(submit&&!nonempty(x[f]))throw Error('두 직업의 모든 탐구 항목을 작성해 주세요.')}}
 function seed(){return [1,2,3].map(n=>({id:'demo-'+n,name:n+'반',code:'DEMO0'+n,stage:1,quota:5,links:'',students:Array.from({length:25},(_,i)=>({id:uid(),no:i+1,name:['김하늘','이서준','박지우','최도윤','정수아'][i%5]+(i<5?'':' '+(Math.floor(i/5)+1)),pin:'12345678',choice:null,research:null})),votes:[]}))}
 let db;const load=()=>db||(db=JSON.parse(localStorage.getItem('career-demo-v1')||'null')||seed());
 const persist=()=>localStorage.setItem('career-demo-v1',JSON.stringify(db));
 function filter(c,session){const out=JSON.parse(JSON.stringify(c));if(session.role==='teacher')return out;out.students=out.students.map(s=>{delete s.pin;if(s.id!==session.sid){delete s.research;if(c.stage<2||!s.choice?.submitted)delete s.choice;}return s});out.votes=out.votes.filter(v=>v.from===session.sid||(c.stage>=3&&v.to===session.sid&&!v.hidden)).map(v=>v.from===session.sid?v:{to:v.to,job:v.job,reason:v.reason,hidden:false});return out}
 function demo(action,p={},session={}){const data=load();if(action==='lookup'){const c=data.find(x=>x.code===p.code);if(!c)throw Error('참여 코드를 확인해 주세요.');return {id:c.id,name:c.name,students:c.students.map(({id,no,name})=>({id,no,name}))}}
 if(action==='student_login'){const c=data.find(x=>x.id===p.classId),s=c?.students.find(x=>x.id===p.sid&&x.pin===p.pin);if(!s)throw Error('이름과 개인 접속 번호를 확인해 주세요.');return {token:'demo',role:'student',classId:c.id,sid:s.id}}
 if(action==='list'){if(session.role!=='teacher')throw Error('교사만 사용할 수 있어요.');return data.map(c=>({id:c.id,name:c.name,stage:c.stage,count:c.students.length}))}
 if(action==='create'){if(session.role!=='teacher')throw Error('교사만 사용할 수 있어요.');const c={id:uid(),name:p.name,code:uid().slice(0,8).toUpperCase(),stage:1,quota:5,links:'',students:[],votes:[]};data.push(c);persist();return c}
 const c=data.find(x=>x.id===(p.classId||session.classId));if(!c)throw Error('학급을 찾을 수 없어요.');if(session.role!=='teacher'&&session.classId!==c.id)throw Error('다른 반에는 접근할 수 없어요.');const me=c.students.find(s=>s.id===session.sid);
 const teacherActions=['roster','stage','settings','rename','reset_pin','moderate','delete','delete_student'];if(teacherActions.includes(action)&&session.role!=='teacher')throw Error('교사만 사용할 수 있어요.');
 if(action==='get')return filter(c,session);if(action==='status')return {stage:c.stage};
 if(action==='roster'){if(c.stage!==1)throw Error('명단 추가는 1단계에서만 할 수 있어요.');const names=p.names.filter(nonempty);if(c.students.length+names.length>40)throw Error('학급당 최대 40명까지 등록할 수 있어요.');const credentials=names.map(name=>({id:uid(),no:Math.max(0,...c.students.map(s=>s.no))+1,name,pin:String(crypto.getRandomValues(new Uint32Array(1))[0]%90000000+10000000),choice:null,research:null}));credentials.forEach((s,i)=>s.no=Math.max(0,...c.students.map(s=>s.no))+i+1);c.students.push(...credentials);persist();return credentials.map(({name,no,pin})=>({name,no,pin}))}
 if(action==='delete_student'){if(c.stage!==1||c.votes.length)throw Error('명단 삭제는 추천 시작 전 1단계에서만 가능해요.');c.students=c.students.filter(s=>s.id!==p.sid);}
 if(action==='rename'){const s=c.students.find(s=>s.id===p.sid);s.name=p.name;}
 if(action==='reset_pin'){const s=c.students.find(s=>s.id===p.sid);s.pin=String(crypto.getRandomValues(new Uint32Array(1))[0]%90000000+10000000);persist();return {name:s.name,no:s.no,pin:s.pin}}
 if(action==='stage'){if(![1,2,3,4,5].includes(+p.stage))throw Error('잘못된 단계');if(+p.stage===1&&c.votes.length)throw Error('추천 시작 후에는 희망 직업을 변경할 수 없어요.');c.stage=+p.stage;}
 if(action==='settings'){if(c.votes.length&&+p.quota!==+c.quota)throw Error('추천이 시작된 후 배정 수를 바꿀 수 없어요.');c.quota=Math.max(1,Math.min(39,+p.quota));c.links=p.links.slice(0,4000);if(p.name)c.name=p.name;}
 if(action==='moderate'){const v=c.votes.find(v=>v.from===p.from&&v.to===p.to);v.hidden=!!p.hidden;}
 if(action==='delete'){db=data.filter(x=>x.id!==c.id);persist();return {ok:true}}
 if(['choice','vote','research'].includes(action)&&(!me||session.role!=='student'))throw Error('학생으로 입장해 주세요.');
 if(action==='choice'){if(c.stage!==1)throw Error('지금은 희망 직업을 수정할 수 없어요.');if(!jobOK(p.job)||typeof p.reason!=='string'||p.reason.length>500||(p.submitted&&!nonempty(p.reason)))throw Error('직업과 선택 이유를 확인해 주세요.');me.choice={job:+p.job,reason:p.reason,submitted:!!p.submitted};}
 if(action==='vote'){if(c.stage!==2)throw Error('친구 추천 시간이 아니에요.');if(!targets(c,me.id).includes(p.to))throw Error('배정된 친구에게 추천해 주세요.');if(!c.students.find(s=>s.id===p.to)?.choice?.submitted)throw Error('친구가 희망 직업을 제출한 뒤 추천해 주세요.');if(!jobOK(p.job)||!nonempty(p.reason)||p.reason.length>500)throw Error('직업과 추천 이유를 작성해 주세요.');const hidden=c.votes.find(v=>v.from===me.id&&v.to===p.to)?.hidden||false;c.votes=c.votes.filter(v=>!(v.from===me.id&&v.to===p.to));c.votes.push({from:me.id,to:p.to,job:+p.job,reason:p.reason,hidden});}
 if(action==='research'){if(c.stage!==4)throw Error('미래 탐구 작성 시간이 아니에요.');validateResearch(p.items,p.submitted);if(!me.choice?.submitted)throw Error('희망 직업을 먼저 제출해야 해요.');if(me.research){if(p.items.some((x,i)=>x.job!==me.research.items[i].job))throw Error('확정한 탐구 직업은 바꿀 수 없어요.');}else if(p.items[0].job!==me.choice.job||!candidates(c,me.id).includes(p.items[1].job))throw Error('탐구 대상 직업을 다시 확인해 주세요.');me.research={items:p.items,submitted:!!p.submitted};}
 persist();return {ok:true};}
 return {fields,ranks,candidates,targets,validateResearch,demo};
})();
