'use strict';
// Cliente de apresentação. Cartas, turnos, regras e placares são decididos pelo servidor.
const ENDPOINT='wss://truco-de-mesa-beta.onrender.com/v1/ws';
const BUILD='0.4.0-beta2', AVATARS=['🧑🏽','👩🏻','🧔🏿','👩🏽','🧑🏻','👩🏿'];
const VARIANTS={paulista:'Paulista',mineiro:'Mineiro',maluco:'Maluco'};
const EVENTS={escuro:'No escuro',surpresa:'Vira surpresa',mineiro:'Virou Mineiro',uma_oculta:'Uma no escuro'};
const RANKS=['4','5','6','7','Q','J','K','A','2','3'], SUITS=['♦','♠','♥','♣'], SUIT_NAMES=['ouros','espadas','copas','paus'];
const ERRORS={BAD_PACKET:'Mensagem inválida.',VERSION_MISMATCH:'Atualize o jogo para entrar neste servidor.',ROOM_NOT_FOUND:'Essa sala não existe ou já encerrou.',ROOM_FULL:'A sala está cheia.',JOIN_PENDING:'Aguarde a aprovação do organizador.',NOT_AUTHORIZED:'Essa ação não está disponível agora.',STALE_REVISION:'A mesa mudou. Confira e tente novamente.',ILLEGAL_ACTION:'Essa jogada não é permitida agora.',ID_REUSED:'Essa tentativa de jogada já foi usada.',RATE_LIMITED:'Aguarde um instante antes de tentar de novo.',MATCH_INTERRUPTED:'A sala foi interrompida, sem vencedor.',NOT_READY:'Todos precisam estar prontos e os lugares precisam estar preenchidos.',BARRIER_PENDING:'Aguarde todos acompanharem a distribuição ou o resultado.',SIGNAL_EXPIRED:'Comece o sinal novamente.',RESUME_EXPIRED:'A sessão anterior expirou. Entre em uma nova sala.',SERVICE_FULL:'O servidor está cheio. Tente novamente mais tarde.',STORAGE_FAILED:'O servidor não conseguiu preservar a partida.'};
const app=document.getElementById('app'), statusLabel=document.getElementById('connection-status'), dot=document.getElementById('connection-dot'), exit=document.getElementById('exit'), dialogLayer=document.getElementById('dialog-layer');
let profile=read('truco-web-profile-v1')||{nickname:'Truqueiro',avatar:0};
if(typeof profile.nickname!=='string'||!Number.isInteger(profile.avatar)||profile.avatar<0||profile.avatar>5)profile={nickname:'Truqueiro',avatar:0};
let token=read('truco-web-session-v1')?.token||'';
if(!/^[a-f0-9]{64}$/.test(token))token='';
let socket=null,connected=false,wanted=false,sessionId='',room=null,attempts=0,deadline=0,retryTimer=0,handshakeTimer=0,lastReceived=0;
let pendingAction=null,selected='',subject='',codeDraft='',variantDraft='paulista',playersDraft=4,deckDraft='sujo',botsDraft=false,covered=false,barrierTimer=0,barrierSent='',signalState=null,toastTimer=0;
const pending=new Map();

function read(key){try{return JSON.parse(localStorage.getItem(key));}catch(_){return null;}}
function save(key,value){try{localStorage.setItem(key,JSON.stringify(value));}catch(_){/* A sessão continua em memória quando o navegador bloqueia o armazenamento. */}}
function id(){return Array.from(crypto.getRandomValues(new Uint8Array(16)),n=>n.toString(16).padStart(2,'0')).join('');}
function integer(n,min,max){return Number.isInteger(n)&&n>=min&&n<=max;}
function node(tag,text='',className=''){const element=document.createElement(tag);if(text!==null)element.textContent=String(text);if(className)element.className=className;return element;}
function append(parent,...children){for(const child of children)if(child)parent.append(child);return parent;}
function button(text,action,className='',disabled=false){const b=node('button',text,className);b.type='button';b.disabled=disabled;b.addEventListener('click',action);return b;}
function paragraph(text,className=''){return node('p',text,className);}
function toast(text){const target=document.getElementById('toast');target.textContent=text;target.hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>target.hidden=true,5000);}
function setStatus(text){statusLabel.textContent=text;dot.className=connected?'online':'';}
function cleanName(text){return text.replace(/[\x00-\x1f\x7f]/g,'').trim().slice(0,20)||'Truqueiro';}
function field(label,value,onInput,options={}){const container=node('label',label);const input=node('input');input.value=value;input.maxLength=options.maxLength||20;input.autocomplete=options.autocomplete||'off';if(options.className)input.className=options.className;if(options.placeholder)input.placeholder=options.placeholder;input.addEventListener('input',()=>onInput(input.value));container.append(input);return container;}
function select(label,values,current,change){const container=node('label',label), control=node('select');for(const [value,text] of values){const option=node('option',text);option.value=value;option.selected=String(current)===String(value);control.append(option);}control.addEventListener('change',()=>change(control.value));container.append(control);return container;}
function playerName(seat){return room?.players?.[seat]?.profile?.nickname||'Jogador';}
function validRoom(r){
  if(!r||typeof r!=='object'||!Array.isArray(r.players)||![2,4,6].includes(r.players.length)||!integer(r.seat,-1,r.players.length-1)||typeof r.code!=='string'||!/^[A-Z2-9]{6}$/.test(r.code)||!integer(r.room_revision,0,2147483647)||!integer(r.lobby_revision,0,2147483647))return false;
  if(!['lobby','active','finished','interrupted'].includes(r.status)||typeof r.suspended!=='boolean'||!Array.isArray(r.pending)||r.pending.length>48||!r.options||!VARIANTS[r.options.variant])return false;
  if(r.players.some(p=>!p||!p.profile||typeof p.profile.nickname!=='string'||p.profile.nickname.length>20||!integer(p.profile.avatar,0,5)))return false;
  if(!r.view||typeof r.view!=='object'||Array.isArray(r.view))return false;
  const v=r.view;if(Object.keys(v).length===0)return true;
  if(['state','snapshot','commands','rng_state','initial_seed','qa'].some(key=>key in v))return false;
  if(!['play','offer','eleven','round_over','hand_over','match_over'].includes(v.phase)||!integer(v.revision,0,2147483647)||v.seat!==r.seat||v.player_count!==r.players.length||!/^[a-f0-9]{16}$/.test(r.match_id))return false;
  if(!Array.isArray(v.hands)||v.hands.length!==r.players.length||!Array.isArray(v.scores)||v.scores.length!==2||v.scores.some(n=>!integer(n,0,100)))return false;
  if(v.hands.some(hand=>!Array.isArray(hand)||hand.length>3||hand.some(c=>!c||!integer(c.card,-1,39)||typeof c.token!=='string'||c.token.length<1||c.token.length>80)))return false;
  if(!Array.isArray(v.trick)||v.trick.length>r.players.length||v.trick.some(c=>!integer(c.seat,0,r.players.length-1)||!integer(c.card,-1,39)))return false;
  return true;
}

function request(kind,body={},stableId=null){
  if(!socket||socket.readyState!==WebSocket.OPEN)return '';
  const rid=stableId||id();socket.send(JSON.stringify({protocol:1,kind,request_id:rid,body}));
  if(!['pong','ping','hello'].includes(kind))pending.set(rid,{kind,at:Date.now()});return rid;
}
function connect(){
  if(wanted)return;wanted=true;attempts=0;deadline=Date.now()+120000;save('truco-web-profile-v1',profile);openSocket();
}
function openSocket(){
  if(!wanted)return;
  if(Date.now()>deadline){wanted=false;connected=false;setStatus('Servidor indisponível');toast('O servidor não respondeu. Confira a conexão e tente novamente.');render();return;}
  setStatus(attempts?'Acordando / reconectando…':'Conectando…');render();
  const ws=new WebSocket(ENDPOINT);socket=ws;
  clearTimeout(handshakeTimer);handshakeTimer=setTimeout(()=>{if(ws.readyState===WebSocket.CONNECTING)ws.close();},20000);
  ws.addEventListener('open',()=>{if(socket!==ws)return;clearTimeout(handshakeTimer);const body={client_build:BUILD,profile:{nickname:cleanName(profile.nickname),avatar:profile.avatar}};if(token)body.resume_token=token;request('hello',body);});
  ws.addEventListener('message',event=>{if(socket!==ws)return;try{if(typeof event.data!=='string'||event.data.length>131072)throw Error('packet');const packet=JSON.parse(event.data);if(packet.protocol!==1||typeof packet.kind!=='string'||!packet.body||typeof packet.body!=='object')throw Error('packet');lastReceived=Date.now();receive(packet);}catch(error){wanted=false;connected=false;ws.close(1008,'Resposta inválida');setStatus('Servidor incompatível');toast('Recebi uma resposta incompatível do servidor. Atualize a página.');render();}});
  ws.addEventListener('close',()=>{if(socket!==ws)return;clearTimeout(handshakeTimer);if(connected)deadline=Date.now()+120000;connected=false;socket=null;cancelSignal(false);if(wanted){attempts++;setStatus(room?'Reconectando · lugar reservado':'Acordando o servidor…');render();retryTimer=setTimeout(openSocket,Math.min(10000,1000*2**Math.min(attempts-1,4)));}else render();});
  ws.addEventListener('error',()=>{/* O evento close conduz a retomada, mantendo o mesmo comando. */});
}
function receive(packet){
  const b=packet.body;
  if(packet.kind==='server_ping'){if(typeof b.nonce==='string')request('pong',{nonce:b.nonce});return;}
  if(packet.kind==='welcome'){
    if(typeof b.session_id!=='string'||!/^[a-zA-Z0-9_-]{16,64}$/.test(b.session_id)||typeof b.resume_token!=='string'||!/^[a-f0-9]{64}$/.test(b.resume_token))throw Error('welcome');
    sessionId=b.session_id;token=b.resume_token;connected=true;attempts=0;barrierSent='';save('truco-web-session-v1',{token});setStatus('Conectado');
    if(pendingAction){const old=pendingAction;pendingAction={body:old.body,rid:request('action',old.body)};}
    render();return;
  }
  if(packet.kind==='room'){
    if(!validRoom(b))throw Error('room');
    if(room?.code===b.code&&b.room_revision<room.room_revision)return;
    room=b;setStatus(b.seat<0?'Aguardando aprovação':b.suspended?'Aguardando os amigos':'Conectado');
    if(!b.view.hands?.[b.seat]?.some(card=>card.token===selected))selected='';
    if(!b.view.can_cover)covered=false;
    render();acknowledgeDeal();return;
  }
  if(packet.kind==='room_left'){room=null;selected='';subject='';pendingAction=null;render();return;}
  if(packet.kind==='ack'){
    pending.delete(packet.request_id);if(pendingAction?.rid===packet.request_id)pendingAction=null;render();return;
  }
  if(packet.kind==='error'){
    pending.delete(packet.request_id);if(pendingAction?.rid===packet.request_id)pendingAction=null;
    if(b.code==='RESUME_EXPIRED'){token='';sessionId='';room=null;pendingAction=null;save('truco-web-session-v1',{token:''});socket?.close();}
    if(b.code==='VERSION_MISMATCH'){wanted=false;connected=false;socket?.close();}
    if(b.code==='STALE_REVISION')request('sync');
    toast(ERRORS[b.code]||'Não foi possível concluir agora.');render();return;
  }
  if(packet.kind==='signal_challenge'){
    if(!signalState?.holding){request('signal_cancel');return;}
    if(typeof b.challenge_id!=='string'||!integer(b.lead_ms,0,1000))throw Error('signal');
    signalState.challenge=b.challenge_id;signalState.start=performance.now()+b.lead_ms;signalFrame();return;
  }
  if(packet.kind==='emote'){if(integer(b.seat,0,5)&&['smile','knock'].includes(b.gesture))toast(playerName(b.seat)+(b.gesture==='smile'?' deu um sorriso 🙂':' bateu na mesa 👊'));}
}
function action(kind,payload={}){
  if(!connected||!room?.view?.phase||pendingAction||room.suspended||room.status==='interrupted'||room.barrier?.id)return;
  const body={command_id:id(),match_id:room.match_id,expected_revision:room.view.revision,action:{type:kind,payload}};
  const rid=request('action',body);if(rid){pendingAction={rid,body};render();}
}
function leave(disconnect=false){
  if(connected)request('leave');room=null;selected='';subject='';pendingAction=null;pending.clear();token='';save('truco-web-session-v1',{token:''});cancelSignal();
  clearTimeout(barrierTimer);barrierSent='';
  if(disconnect){wanted=false;connected=false;clearTimeout(retryTimer);socket?.close();socket=null;setStatus('Desconectado');}
  render();
}
function acknowledge(){
  const barrier=room?.barrier;if(!connected||!barrier?.id||barrier.mine_ready||barrierSent===barrier.id)return;
  barrierSent=barrier.id;request('barrier_ack',{match_id:room.match_id,revision:barrier.revision,barrier_id:barrier.id});
}
function acknowledgeDeal(){
  clearTimeout(barrierTimer);
  if(room?.barrier?.kind==='deal'&&!room.barrier.mine_ready){const current=room.barrier.id;barrierTimer=setTimeout(()=>{if(room?.barrier?.id===current)acknowledge();},850);}
}

function render(){
  app.replaceChildren();exit.hidden=!wanted&&!connected;document.getElementById('footnote').hidden=!!room?.view?.phase;
  if(room?.view?.phase){renderMatch();return;}
  if(room){renderLobby();return;}
  if(connected){renderChoose();return;}
  renderConnect();
}
function renderConnect(){
  const intro=node('section','','intro');append(intro,node('div','JOGAR COM AMIGOS','eyebrow'),node('h1','Todo mundo na mesma mesa.'),paragraph('iPhone, Android e computador entram juntos pelo código da sala.'));
  const panel=node('form','','panel stack');let draft=profile.nickname;
  append(panel,field('SEU APELIDO',profile.nickname,value=>draft=value,{maxLength:20,autocomplete:'nickname'}),node('label','SEU AVATAR'));
  const avatars=node('div','','avatar-picker');
  AVATARS.forEach((avatar,index)=>{const b=button(avatar,()=>{profile.avatar=index;for(const [i,child] of Array.from(avatars.children).entries())child.setAttribute('aria-pressed',String(i===index));});b.setAttribute('aria-label','Avatar '+(index+1));b.setAttribute('aria-pressed',String(profile.avatar===index));avatars.append(b);});panel.append(avatars);
  const submit=button(wanted?'CONECTANDO…':'ENTRAR NO SERVIDOR',()=>{},'primary wide',wanted);submit.type='submit';panel.addEventListener('submit',event=>{event.preventDefault();if(wanted)return;profile.nickname=cleanName(draft);connect();});
  append(panel,submit,paragraph('O servidor gratuito pode levar cerca de um minuto para acordar.','muted'));
  if(wanted)panel.append(button('CANCELAR',()=>leave(true),'quiet'));
  append(intro,panel);app.append(intro);
}
function renderChoose(){
  append(app,node('h1','Bora jogar, '+profile.nickname+'.'),paragraph('Crie uma mesa ou entre com o código que seu amigo passou.'));
  const columns=node('div','','columns spacer'),create=node('form','','panel stack'),join=node('form','','panel stack');
  append(create,node('h2','Crie sua mesa'),select('JOGADORES',[[2,'1 × 1 · 2 pessoas'],[4,'2 × 2 · 4 pessoas'],[6,'3 × 3 · 6 pessoas']],playersDraft,value=>playersDraft=Number(value)),select('VARIANTE',Object.entries(VARIANTS),variantDraft,value=>{variantDraft=value;if(value!=='paulista')deckDraft='sujo';render();}),select('BARALHO',variantDraft==='paulista'?[['sujo','Sujo · 40 cartas'],['limpo','Limpo · 24 cartas']]:[['sujo','Sujo · 40 cartas']],deckDraft,value=>deckDraft=value));
  const check=node('label','Completar lugares com bots','check-label'),checkbox=node('input');checkbox.type='checkbox';checkbox.checked=botsDraft;checkbox.addEventListener('change',()=>botsDraft=checkbox.checked);check.prepend(checkbox);create.append(check);
  const createButton=button('CRIAR SALA',()=>{},'primary wide');createButton.type='submit';create.append(createButton);create.addEventListener('submit',event=>{event.preventDefault();request('create_room',{players:playersDraft,variant:variantDraft,deck_mode:deckDraft,bots:botsDraft});});
  append(join,node('h2','Entre na sala'),paragraph('Use o mesmo código de quem está no aplicativo Android.'),field('CÓDIGO DA SALA',codeDraft,value=>codeDraft=value.toUpperCase(),{maxLength:6,className:'code-input',placeholder:'6 LETRAS / NÚMEROS'}));
  const joinButton=button('ENTRAR POR CÓDIGO',()=>{},'primary wide');joinButton.type='submit';join.append(joinButton);join.addEventListener('submit',event=>{event.preventDefault();codeDraft=codeDraft.trim().toUpperCase();if(!/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/.test(codeDraft)){toast('Confira o código de 6 letras e números.');return;}request('join_room',{code:codeDraft});});
  join.append(paragraph('O organizador aprova sua entrada. Depois, todos confirmam que estão prontos.','muted'));append(columns,create,join);app.append(columns);
}
function renderLobby(){
  const r=room,owner=r.owner===sessionId;const heading=node('div','','room-heading'),identity=node('div');append(identity,node('div','CÓDIGO DA SALA','eyebrow'),node('div',r.code,'room-code'));append(heading,identity,button('COPIAR CÓDIGO',async()=>{try{await navigator.clipboard.writeText(r.code);toast('Código copiado: '+r.code);}catch(_){toast('Código da sala: '+r.code);}},'quiet'));app.append(heading);
  if(r.seat<0){append(app,node('section','','panel stack'));append(app.lastChild,node('h2','Aguardando o organizador'),paragraph('Sua entrada precisa ser aprovada antes de escolher o lugar.'),button('CANCELAR ENTRADA',()=>leave(),'quiet'));return;}
  append(app,paragraph(VARIANTS[r.options.variant]+' · '+(r.options.players/2)+' × '+(r.options.players/2)+' · '+(r.options.bots?'Bots completam a mesa':'Somente pessoas'),'muted'));
  const seats=node('div','','seats');r.players.forEach((person,index)=>{
    const name=person.sid?person.profile.nickname:r.options.bots?'Bot ao começar':'Lugar livre';
    const b=button('',()=>{
      if(!connected)return;
      if(owner){if(!subject){subject=person.sid||sessionId;render();}else{request('seat_assign',{lobby_revision:r.lobby_revision,seat:index,subject_id:subject});subject='';}}
      else if(!person.sid)request('seat_request',{lobby_revision:r.lobby_revision,seat:index});
    },'seat '+(index%2?'terra':'')+(subject&&subject===person.sid?' chosen':''));
    b.setAttribute('aria-label','Lugar '+(index+1)+': '+name);const info=node('span','','seat-info');append(info,node('strong',(index===r.seat?'VOCÊ · ':'')+name),node('small',(index%2?'TIME TERRA':'TIME VERDE')+' · '+(!person.sid?'LIVRE':person.ready?'PRONTO':person.connected?'ESCOLHENDO':'DESCONECTADO')));append(b,node('span',AVATARS[person.profile.avatar],'avatar'),info);seats.append(b);
  });app.append(seats);
  if(owner&&r.pending.length){const person=r.pending[0],box=node('div','','pending');append(box,node('strong',person.profile.nickname+' quer entrar.'),append(node('div','','row'),button('APROVAR',()=>request('join_decision',{lobby_revision:room.lobby_revision,applicant_id:person.id,accept:true}),'primary'),button('RECUSAR',()=>request('join_decision',{lobby_revision:room.lobby_revision,applicant_id:person.id,accept:false}),'quiet')));app.append(box);}
  app.append(paragraph(subject?'Agora toque no lugar de destino.':owner?'Toque em uma pessoa e depois no lugar de destino para trocar.':'Você pode tocar em um lugar livre para mudar de cadeira.','muted'));
  const actions=node('div','','lobby-actions'),ready=r.players[r.seat].ready;actions.append(button(ready?'NÃO ESTOU PRONTO':'ESTOU PRONTO',()=>request('ready',{lobby_revision:room.lobby_revision,ready:!ready}),ready?'quiet':'primary'));
  if(owner)actions.append(button('COMEÇAR PARTIDA',()=>request('start_match',{lobby_revision:room.lobby_revision}),'primary'));
  else actions.append(paragraph('O organizador começa a partida.','muted'));
  actions.append(button('SAIR DA SALA',()=>leave(),'quiet'));app.append(actions);
}

function cardView(value,interactive=false,tokenValue=''){
  const unknown=value<0;const label=unknown?'Carta oculta':RANKS[Math.floor(value/4)]+' de '+SUIT_NAMES[value%4];
  const card=node(interactive?'button':'div','','card'+(unknown?' back':value%4===0||value%4===2?' red':'')+(interactive&&selected===tokenValue?' selected':''));
  card.setAttribute('aria-label',label);if(interactive){card.type='button';card.setAttribute('aria-pressed',String(selected===tokenValue));card.addEventListener('click',()=>{selected=tokenValue;render();});card.addEventListener('dblclick',()=>{if(room?.view.can_play){selected=tokenValue;playSelected();}});}
  if(unknown)card.append(node('span','♣'));
  else append(card,node('span',RANKS[Math.floor(value/4)]),node('span',SUITS[value%4],'suit'));
  return card;
}
function playSelected(){if(!room?.view.can_play||!selected)return;action('play',{token:selected,covered:covered&&!!room.view.can_cover});}
function renderMatch(){
  const r=room,v=r.view,myTeam=r.seat%2,blocked=!connected||r.suspended||r.status==='interrupted';
  if(r.status==='finished'){renderResult();return;}
  if(blocked){const banner=node('div','','blocking');append(banner,node('strong',r.status==='interrupted'?'MESA INTERROMPIDA':'AGUARDANDO CONEXÃO'),paragraph(r.status==='interrupted'?'A sala foi encerrada sem atribuir vencedor.':'A mesa aguarda os amigos voltarem. O lugar fica reservado por até 90 segundos após a queda ser detectada.'));if(r.status==='interrupted')banner.append(button('VOLTAR AO INÍCIO',()=>leave(),'quiet'));app.append(banner);}
  const scorebar=node('div','','scorebar'),score=node('div','','score');append(score,node('span','Seu time '+v.scores[myTeam],'green'),node('span','  ×  '),node('span',v.scores[1-myTeam]+' Adversários','terra'));
  const info=node('div','','match-info');append(info,node('strong',VARIANTS[v.variant]+' · SALA '+r.code),node('span','Mão '+v.hand_no+' · '+(v.variant==='maluco'?EVENTS[v.rule]||'Paulista':v.iron?'Mão de ferro':'Vale '+v.accepted)));append(scorebar,score,info);app.append(scorebar);
  const layout=node('div','','match-layout'),arena=node('section','','arena'),players=node('div','','players');
  r.players.forEach((person,index)=>{if(index===r.seat)return;const name=person.profile.nickname+(person.bot?' 🤖':'');const tag=node('div',name+' · '+(v.hands[index]?.length||0)+' cartas','player-tag'+(index%2?' terra':'')+(index===v.turn&&v.phase==='play'?' turn':''));tag.title='Lugar '+(index+1)+' · '+(index%2===myTeam?'Seu time':'Adversário');players.append(tag);});arena.append(players);
  const felt=node('div','','felt');let note=v.can_play?'Sua vez · escolha uma carta':v.phase==='play'?'Vez de '+playerName(v.turn):v.phase==='offer'?playerName(v.offer_seat)+' pediu '+v.offer+'!':v.phase==='eleven'?'Mão de '+v.special_limit+' · seu time decide':v.phase==='hand_over'?v.hand_winner===myTeam?'Seu time ganhou a mão!':'Adversários ganharam a mão':v.phase==='round_over'?'Resultado da rodada':'';
  if(r.barrier?.kind==='deal')note='Distribuindo as cartas…';
  if(pendingAction)note='Enviando jogada…';felt.append(node('div',note,'table-note'));
  if(v.hand_variant!=='mineiro'){const vira=node('div','','vira');append(vira,node('span','VIRA'),cardView(v.vira));felt.append(vira);}
  const trick=node('div','','trick');for(const play of v.trick){const played=node('div','','table-card');append(played,cardView(play.card),node('small',playerName(play.seat)));trick.append(played);}felt.append(trick);
  const rounds=(v.rounds||[]).map((winner,index)=>'R'+(index+1)+': '+(winner<0?'Empate':winner===myTeam?'Seu time':'Adversários')).join(' · ');felt.append(node('div',rounds,'rounds'));arena.append(felt);
  const myArea=node('div','','my-area'),hand=node('div','','hand');for(const c of v.hands[r.seat]||[])hand.append(cardView(c.card,true,c.token));append(myArea,hand,node('div',profile.nickname+' · '+(v.blind?'Mão às cegas':v.rule==='uma_oculta'?'A terceira carta está oculta':'Toque na carta e depois em JOGAR'),'my-caption'));arena.append(myArea);
  const controls=node('aside','','actions-panel'),disabled=blocked||!!pendingAction||!!r.barrier?.id;
  if(r.barrier?.id){controls.append(button(r.barrier.mine_ready?'AGUARDANDO A MESA':r.barrier.kind==='deal'?'RECEBENDO CARTAS…':r.barrier.kind==='hand'?'PRÓXIMA MÃO':'CONTINUAR RODADA',acknowledge,'primary',r.barrier.mine_ready||blocked||r.barrier.kind==='deal'));}
  else if(v.can_respond){append(controls,paragraph('Vale '+v.offer+' pontos. Seu time decide.'),button('ACEITAR '+v.offer,()=>action('accept'),'primary',disabled));if(v.next_bid>0)controls.append(button('AUMENTAR PARA '+v.next_bid,()=>action('counter'),'quiet',disabled));controls.append(button('CORRER',()=>confirmDialog('Correr desta mão?','A mão será entregue ao outro time pelo valor permitido nesta oferta.',()=>action('fold')),'danger',disabled));}
  else if(v.can_decide_eleven){append(controls,paragraph('Jogar por '+v.special_points+' pontos?'),button('VAMOS JOGAR',()=>action('eleven_yes'),'primary',disabled),button('MELHOR NÃO',()=>action('eleven_no'),'quiet',disabled));}
  else{controls.append(button('JOGAR CARTA',playSelected,'primary',disabled||!v.can_play||!selected));if(v.can_raise)controls.append(button('PEDIR '+(v.next_bid===3?'TRUCO':v.next_bid),()=>action('raise'),'quiet',disabled));if(v.can_cover)controls.append(button(covered?'COBERTA: SIM':'JOGAR COBERTA',()=>{covered=!covered;render();},covered?'primary':'quiet',disabled));if(v.can_concede)controls.append(button('ENTREGAR A MÃO',()=>confirmDialog('Entregar esta mão?','O outro time receberá os pontos previstos para a entrega.',()=>action('concede')),'quiet',disabled));}
  if(v.can_signal)controls.append(button('SINAL AO TIME',signalDialog,'quiet',disabled));
  if(v.phase==='offer'&&!v.can_respond){const opinion=node('div','','small-actions');for(const [decision,text] of [['fold','Correr'],['accept','Topo'],['counter','Subir']])opinion.append(button(text,()=>request('opinion',{match_id:r.match_id,revision:v.revision,decision}),'quiet',blocked));controls.append(opinion);}
  const opinions=Object.entries(r.opinions||{});if(opinions.length)controls.append(paragraph(opinions.map(([seat,decision])=>playerName(Number(seat))+': '+({fold:'melhor correr',accept:'topa',counter:'pode aumentar'}[decision]||'')).join(' · '),'muted'));
  const emotes=node('div','','small-actions');for(const [gesture,text,label] of [['smile','🙂','Sorrir'],['knock','👊','Bater na mesa']]){const b=button(text,()=>request('emote',{gesture}),'quiet',blocked);b.setAttribute('aria-label',label);emotes.append(b);}controls.append(emotes);
  if(v.signals?.length){const signal=v.signals[v.signals.length-1];const labels={zap:'Zap ♣',copas:'Copas ♥',espadas:'Espadilha ♠',ouros:'Pica-fumo ♦',fraca:'Mão fraca',segura:'Segura a mão'};controls.append(paragraph(playerName(signal.seat)+': '+(labels[signal.kind]||signal.kind)+(signal.visibility==='private'?' · só seu time':' · público'),'muted'));}
  append(layout,arena,controls);app.append(layout);
}
function renderResult(){
  const r=room,v=r.view,myTeam=r.seat%2;const panel=node('section','','panel result-panel stack');append(panel,node('div','FIM DE PARTIDA','eyebrow'),node('h1',v.scores[myTeam]>v.scores[1-myTeam]?'Seu time ganhou!':'Boa partida!'),node('div',v.scores[myTeam]+' × '+v.scores[1-myTeam],'score'),paragraph('Resultado confirmado pelo servidor.'),button(r.rematch_ready?'AGUARDANDO OS AMIGOS':'QUERO REVANCHE',()=>request('rematch',{match_id:r.match_id}),'primary',!connected||r.rematch_ready),paragraph(r.rematch_count+' pessoa(s) pronta(s) para a revanche.','muted'),button('VOLTAR ÀS SALAS',()=>leave(),'quiet'));app.append(panel);
}
function confirmDialog(title,text,confirm){dialogLayer.replaceChildren();const shade=node('div','','shade'),dialog=node('section','','dialog stack');dialog.setAttribute('role','dialog');dialog.setAttribute('aria-modal','true');dialog.setAttribute('aria-label',title);append(dialog,node('h2',title),paragraph(text),append(node('div','','row'),button('CANCELAR',()=>dialogLayer.replaceChildren(),'quiet'),button('CONFIRMAR',()=>{dialogLayer.replaceChildren();confirm();},'primary')));shade.append(dialog);dialogLayer.append(shade);}
function signalDialog(){
  dialogLayer.replaceChildren();const shade=node('div','','shade'),dialog=node('section','','dialog stack');dialog.setAttribute('role','dialog');dialog.setAttribute('aria-modal','true');dialog.setAttribute('aria-label','Sinal ao time');append(dialog,node('h2','Sinal ao time'),paragraph('Escolha o sinal. Segure e solte na faixa verde para mostrar só ao seu time. Fora dela, todos verão.'));
  let kind='zap';dialog.append(select('SINAL',[['zap','Zap ♣'],['copas','Copas ♥'],['espadas','Espadilha ♠'],['ouros','Pica-fumo ♦'],['fraca','Mão fraca'],['segura','Segura a mão']],kind,value=>kind=value));const meter=node('div','','signal-meter'),needle=node('div','','signal-needle');meter.append(needle);const hold=button('SEGURE AQUI',()=>{},'hold primary');
  const begin=event=>{if(signalState?.holding||!connected||!room?.view.can_signal)return;if(event.type==='keydown'&&![' ','Enter'].includes(event.key))return;event.preventDefault();signalState={holding:true,challenge:'',start:Infinity,hold,needle};if(event.pointerId!==undefined)hold.setPointerCapture(event.pointerId);hold.textContent='PREPARANDO SINAL…';request('signal_begin',{match_id:room.match_id,expected_revision:room.view.revision,signal:kind});};
  const end=event=>{if(!signalState?.holding)return;if(event.type==='keyup'&&![' ','Enter'].includes(event.key))return;event.preventDefault();const state=signalState;if(state.challenge&&performance.now()>=state.start)request('signal_end',{match_id:room.match_id,challenge_id:state.challenge});else request('signal_cancel');signalState=null;dialogLayer.replaceChildren();};
  hold.addEventListener('pointerdown',begin);hold.addEventListener('pointerup',end);hold.addEventListener('pointercancel',()=>cancelSignal());hold.addEventListener('keydown',begin);hold.addEventListener('keyup',end);
  append(dialog,meter,hold,button('FECHAR',()=>{cancelSignal();dialogLayer.replaceChildren();},'quiet'));shade.append(dialog);dialogLayer.append(shade);
}
function signalFrame(){const s=signalState;if(!s?.holding)return;const elapsed=Math.max(0,performance.now()-s.start);s.needle.style.left=Math.min(99,elapsed/1600*100)+'%';s.hold.textContent=elapsed>=650&&elapsed<=1050?'SOLTE AGORA · SÓ SEU TIME VÊ':elapsed>1050?'FORA DO VERDE · TODOS VERÃO':'ESPERE O VERDE…';requestAnimationFrame(signalFrame);}
function cancelSignal(send=true){if(signalState&&send&&connected)request('signal_cancel');signalState=null;}
exit.addEventListener('click',()=>confirmDialog('Sair da mesa?','Você deixará sua sala. Os outros jogadores poderão continuar ou abrir outra mesa.',()=>leave(true)));
document.addEventListener('visibilitychange',()=>{if(document.hidden){cancelSignal();dialogLayer.replaceChildren();}else if(connected&&Date.now()-lastReceived>45000)socket?.close();});
window.addEventListener('online',()=>{if(wanted&&!socket){clearTimeout(retryTimer);openSocket();}});
setInterval(()=>{if(connected&&Date.now()-lastReceived>45000)socket?.close();for(const [rid,p] of pending){if(Date.now()-p.at>20000){pending.delete(rid);if(pendingAction?.rid===rid)socket?.close();}}},2000);
if('serviceWorker' in navigator)navigator.serviceWorker.register('../sw.js',{scope:'../',updateViaCache:'none'}).catch(()=>{});
render();
