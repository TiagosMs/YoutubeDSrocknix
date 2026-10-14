# YouTube DS (ROCKNIX / Anbernic RG DS)

Cliente nativo do YouTube estilo **App Mobile** para consoles portáteis de duas telas rodando **ROCKNIX** (como o **Anbernic RG DS** com chip Rockchip RK3566).

Interface gráfica OpenGL ES a 60 FPS com tema escuro moderno do YouTube, suporte a reprodução na tela superior (`DSI-2`), navegação por touch e controle físico completo na tela inferior (`DSI-1`), mini-player em segundo plano, busca avançada e sincronização de conta para recomendações personalizadas.

---

## 🎮 Funcionalidades Principais

- **Dual-Screen Otimizado**:
  - **Tela Superior (`DSI-2`)**: Decodificação por hardware a 60 FPS (H.264 360p) via `mpv` com Wayland Shared Memory (`--vo=wlshm`). Preview instantâneo de thumbnails ao navegar pela lista.
  - **Tela Inferior (`DSI-1`)**: Interface gráfica nativa Love2D 11.5 com aceleração GPU Mali, navegação fluida, mini-player integrado e carrossel de categorias.
- **Mini-Player em Segundo Plano**:
  - Continue navegando pela **Home**, **Em Alta**, **Buscar**, **Inscrições** e **Você** enquanto o vídeo toca ininterruptamente na tela de cima.
  - Barra compacta acima do menu inferior com progresso do vídeo, título, Play/Pause, tela cheia e botão de fechar.
- **Controle Físico Completo (Sem necessidade de Touch)**:
  - Navegue por todas as abas com os botões de ombro (`L1`/`R1`).
  - Alterne categorias com `L2`/`R2` ou `D-Pad ← / →`.
  - Digite no teclado virtual usando o D-Pad + `A`, `X` (Backspace), `START` (Buscar).
  - Controle de reprodução instantâneo com `X` (Play/Pause global).
- **Busca Rápida**:
  - Teclado virtual on-screen com suporte a toque direto na tela.
  - Pílulas com sugestões de termos rápidos (`Jogos Retrô`, `Nintendo DS`, `Super Mario`, `Pokemon`, `Zelda`, `Speedrun`).
- **Sincronização de Conta & Recomendações**:
  - Portal de conexão local hospedado no próprio console: `http://<IP_DO_CONSOLE>:8989/connect`.
  - **Opção 1**: Cole seus cookies do YouTube para ter seu feed real (`FEwhat_to_watch`) e suas inscrições (`FEsubscriptions`).
  - **Opção 2**: Defina tópicos e canais favoritos para gerar um feed personalizado instantâneo.
- **Streaming Ultrarrápido**:
  - Extração direta via YouTube Innertube API (~0.4s para iniciar stream, ~1.1s para busca), sem timeouts de scraping.

---

## 🕹️ Mapeamento de Controles

| Botão | Função no Feed / Abas | Função na Busca | No Player Expandido |
| :--- | :--- | :--- | :--- |
| **`L1` / `R1`** | Alternar entre as 5 abas (`Início`, `Em Alta`, `Buscar`, `Inscrições`, `Você`) | Alternar abas | - |
| **`L2` / `R2`** | Alternar categorias de vídeos | - | Volume - / + |
| **`D-Pad ↑ / ↓`** | Rolar cards de vídeos | Linhas do teclado / Sugestões | - |
| **`D-Pad ← / →`** | Trocar categoria no feed | Colunas do teclado | Retroceder / Avançar 10s |
| **`A`** | Reproduzir vídeo / Confirmar seleção | Digitar letra / Selecionar sugestão | - |
| **`B`** | Fechar vídeo / Voltar ao Início | Voltar ao Feed | Minimizar para o Mini-Player |
| **`X`** | **Play / Pause instantâneo** | Apagar caractere (Backspace) | Play / Pause |
| **`Y`** | Atalho para Buscar | Limpar texto de busca | Fechar reprodução |
| **`START`** | Executar Busca | **Buscar imediatamente** | Play / Pause |
| **`SELECT`** | Sair do Port | Sair do Port | Sair do Port |

*Nota: Todas as funções também podem ser acionadas diretamente por toque na tela inferior (`DSI-1`).*

---

## 📥 Instalação no ROCKNIX

### Método Automático (via SSH no Console)

Conecte-se ao seu console via SSH (ex: `ssh root@192.168.0.xxx`) e execute:

```bash
curl -sL https://raw.githubusercontent.com/TiagosMs/YoutubeDSrocknix/main/install.sh | bash
```

### Método Manual

1. Copie o arquivo `YouTube.sh` para `/storage/roms/ports/YouTube.sh`.
2. Copie a pasta `youtube/` para `/storage/roms/ports/youtube/`.
3. Dê permissão de execução:
   ```bash
   chmod +x /storage/roms/ports/YouTube.sh
   chmod +x /storage/roms/ports/youtube/api_server.py
   ```
4. Baixe o `yt-dlp` como fallback opcional:
   ```bash
   curl -sL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /storage/roms/ports/youtube/yt-dlp
   chmod +x /storage/roms/ports/youtube/yt-dlp
   ```
5. Atualize os jogos na lista de **Ports** no EmulationStation.

---

## 🔗 Conectando sua Conta

1. No console, vá até a aba **Você** (5ª aba no menu inferior).
2. O console exibirá o endereço local, por exemplo:
   `http://192.168.0.xxx:8989/connect`
3. No celular ou PC conectado na mesma rede Wi-Fi, abra esse link no navegador.
4. Escolha como sincronizar:
   - **Cookies**: Exporte os cookies do YouTube pelo navegador (com a extensão *Get cookies.txt LOCALLY* ou pelo F12) e cole na página.
   - **Tópicos**: Digite seus temas e canais favoritos separados por vírgula.
5. Clique em **Salvar** — o YouTube DS no portátil sincronizará imediatamente!

---

## 📁 Estrutura de Arquivos

```
/storage/roms/ports/
├── YouTube.sh                  # Script launcher do Port (gerencia Sway, DSI-1/2, mpv e love)
└── youtube/
    ├── api_server.py           # Daemon backend (Innertube API, MPV IPC, cache, portal web)
    ├── auth.json               # Configurações de autenticação e preferências (local)
    ├── cache/                  # Cache local de thumbnails
    ├── yt-dlp                  # Binário fallback para extração de streams
    └── app/
        ├── conf.lua            # Configurações de janela Love2D (640x480 GLES)
        └── main.lua            # Interface gráfica do YouTube (Lua + Love2D)
```

---

## 📜 Licença

Distribuído sob a licença MIT. Sinta-se livre para usar, modificar e distribuir.
