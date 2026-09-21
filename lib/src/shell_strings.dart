import 'package:flutter/material.dart';

/// The user-facing languages the shell ships. [code] is the BCP-47 tag
/// persisted in SharedPreferences and handed to `Locale` by hosts;
/// [nativeName] is how the language calls itself — always rendered in its
/// own language, so a player who cannot read the current UI can still find
/// their language in the picker.
enum ShellLanguage {
  english('en', 'English'),
  italiano('it', 'Italiano');

  const ShellLanguage(this.code, this.nativeName);

  final String code;
  final String nativeName;

  /// The language as a MaterialApp locale.
  Locale get locale => Locale(code);
}

/// Every user-facing string the shared shell renders, per language.
///
/// The default constructor IS the English catalog — the shell's historical
/// strings, kept byte-identical so the consumers' text pins (widget keys are
/// API, and so are the strings their tests find) keep passing. Other
/// languages arrive as additional named constructors; adding one means an
/// enum value, a constructor, and a line in [forLanguage].
///
/// Host-supplied text (the splash's `appName`/`description`/flavor lines,
/// step titles, game-section cards) is the host's to localize — the shell
/// only carries its own vocabulary. Interpolated strings are methods so the
/// word order can differ per language.
@immutable
class ShellStrings {
  const ShellStrings({
    // Top bar.
    this.switchThemeTooltip = 'Switch day/night theme',
    this.settingsTooltip = 'Settings',
    // Splash.
    this.newGame = 'NEW GAME',
    this.continueDefault = 'CONTINUE',
    this.noSavedGames = 'NO SAVED GAMES',
    // Settings screen.
    this.settingsTitle = 'SETTINGS',
    this.accountHeader = 'ACCOUNT',
    this.guest = 'Guest',
    this.checkYourInbox = 'CHECK YOUR INBOX',
    this.verificationCodeLabel = 'Verification code',
    this.verificationCodeHint = 'the 6 digits from the email',
    this.confirm = 'Confirm',
    this.resendEmail = 'Resend email',
    this.useDifferentAddress = 'Use a different address',
    this.signInPitch =
        'Sign in to keep your name, saves and shared games on the cloud. Email comes first; other providers can join later.',
    this.emailLabel = 'Email',
    this.emailHint = 'you@example.com',
    this.passwordLabel = 'Password (cloud account)',
    this.passwordHint = '6+ characters — registers on first use',
    this.signInWithEmail = 'Sign in with email',
    this.serverOnboardingHint =
        'Cloud accounts register on your game server — connect once below (the same connection online multiplayer uses).',
    this.connectGameServer = 'Connect game server',
    this.createOrSignInCloud = 'Create / sign in to cloud account',
    this.cloudAccountReady =
        'Cloud account — verified by your game server, ready for cloud saves.',
    this.deviceLocalAccount =
        'Remembered on this device only. Add a password above for a cloud account.',
    this.signOut = 'Sign out',
    this.playerNameHeader = 'PLAYER NAME',
    this.playerNameLabel = 'How the realm addresses you',
    this.saveName = 'Save name',
    this.language = 'Language',
    this.moreLanguagesComing = 'more languages coming',
    this.settingsFooter =
        'Settings are stored on this device. Signing in prepares them for cloud sync.',
    this.invalidEmail = 'Enter a valid email address',
    this.shortPassword = 'Choose a password of at least 6 characters.',
    this.enterCode = 'Enter the code from the email.',
    this.confirmationResent = 'Confirmation email sent again.',
    this.cancel = 'Cancel',
    // Lobby wizard.
    this.back = 'Back',
    this.continueLabel = 'Continue',
    // Interpolated patterns ({tokens} replaced by the methods below).
    this.welcomePattern = 'Welcome, {name}, to {app}',
    this.welcomeBackPattern = 'Welcome back, {name} — {app} awaits',
    this.signedInAsPattern = 'Signed in as {email}',
    this.confirmationSentPattern =
        'We sent a confirmation to {email}. Enter the code from the email — or open its link — to finish registering.',
    this.stepHeaderPattern = 'Step {step} of {total} — {title}',
    // Multiplayer core (room card, handover section, server dialog).
    this.hostedHere = ' — hosted here',
    this.claimHost = 'Claim host',
    this.roomOptions = 'Room options',
    this.hostOfThisRoom = 'Host of this room',
    this.youSuffix = '(you)',
    this.readyLabel = 'is ready',
    this.notReadyLabel = 'has not readied up yet',
    this.passwordProtected = 'password-protected',
    this.notStartedYet = 'not started yet',
    this.cancelHandover = 'Cancel handover',
    this.handOverHost = 'Hand over host',
    this.promoteSeatHint = 'Promote a seat; the world continues',
    this.deleteRoom = 'Delete room',
    this.endsWorldHint = 'Ends the world for every seat',
    this.leaveRoom = 'Leave room',
    this.seatLeavesHint = 'Your seat leaves; the world continues',
    this.chooseHostBody =
        'Choose the seat that becomes the host. The world keeps running; they claim host powers from their device.',
    this.keepIt = 'Keep it',
    this.deleteForEveryone = 'Delete for everyone',
    this.stay = 'Stay',
    this.leave = 'Leave',
    this.pendingHandovers = 'PENDING HOST HANDOVERS',
    this.dialogServerTitle = 'Game server',
    this.serverUrlLabel = 'Server URL',
    this.serverUrlHint = 'e.g. https://games.example.org',
    this.anonKeyLabel = 'Supabase anon key',
    this.anonKeyHint = 'empty for a bare PostgREST',
    this.anonKeyHelper = 'VM: grep ANON_KEY env · Studio → Settings → API',
    this.connect = 'Connect',
    this.worldTitlePattern = 'World {code}',
    this.clockStatusPattern = 'clock {n}',
    this.hostHandoverPendingPattern = 'host handover to {name} pending',
    this.acceptPromotionPattern =
        'Accept the promotion of {name} on this device',
    this.withdrawPromotionPattern = 'Withdraw the pending promotion of {name}',
    this.handoverPickerTitlePattern = 'Hand over world {code}',
    this.deleteRoomTitlePattern = 'Delete world {code}?',
    this.deleteRoomBodyPattern =
        'The room is removed for every seat — {seats}. Their devices keep nothing but their local saves. This cannot be undone.',
    this.leaveRoomTitlePattern = 'Leave world {code}?',
    this.leaveRoomBodyAllPattern =
        'Your seat departs and the world keeps running for {seats} — your local save stays on this device.',
    this.leaveRoomBodySeatPattern =
        'Your seat ({name}) is removed from the roster. The world keeps running for {others}.',
    // Direct entry + shared lobby step.
    this.directEntry = 'PLAY',
    this.soloStart = 'START SOLO',
    this.addSeat = 'Add seat',
    this.seatsHeader = 'BANNERS',
    this.joinSectionHeader = 'JOIN A GAME',
    this.gameNumberLabel = 'Game number',
    this.gameNumberHint = 'e.g. K7QX2',
    this.joinGame = 'JOIN GAME',
    this.gameNumberMissing = 'Enter the game number the host shared.',
    this.gameRoomMissing =
        'No game answers at that number — check it with the host.',
    this.gameWrongPassword = 'Wrong game password.',
    this.gameJoinFailed = 'Could not reach the game server. Try again.',
    this.joinPasswordLabel = 'Game password (if the host set one)',
    this.hotSeatNote =
        'Same-device seats — pass the device around between banners.',
    this.removeSeatTooltip = 'Remove this seat',
    this.youMarker = '(you)',
  });

  /// The Italian catalog. Word order and idiom follow Italian, not the
  /// English source — the {token} patterns below carry their own phrasing.
  const ShellStrings.italian()
      : switchThemeTooltip = 'Cambia tema giorno/notte',
        settingsTooltip = 'Impostazioni',
        newGame = 'NUOVA PARTITA',
        continueDefault = 'CONTINUA',
        noSavedGames = 'NESSUNA PARTITA SALVATA',
        settingsTitle = 'IMPOSTAZIONI',
        accountHeader = 'ACCOUNT',
        guest = 'Ospite',
        checkYourInbox = 'CONTROLLA LA TUA EMAIL',
        verificationCodeLabel = 'Codice di verifica',
        verificationCodeHint = 'le 6 cifre della mail',
        confirm = 'Conferma',
        resendEmail = 'Reinvia email',
        useDifferentAddress = 'Usa un altro indirizzo',
        signInPitch =
            'Accedi per conservare nome, salvataggi e partite condivise sul cloud. Prima la email; gli altri provider potranno unirsi più avanti.',
        emailLabel = 'Email',
        emailHint = 'tu@esempio.com',
        passwordLabel = 'Password (account cloud)',
        passwordHint = '6+ caratteri — registra al primo uso',
        signInWithEmail = 'Accedi con email',
        serverOnboardingHint =
            'Gli account cloud si registrano sul tuo game server — connettilo una volta qui sotto (la stessa connessione che usa il multiplayer online).',
        connectGameServer = 'Connetti game server',
        createOrSignInCloud = 'Crea / accedi all\'account cloud',
        cloudAccountReady =
            'Account cloud — verificato dal tuo game server, pronto per i salvataggi sul cloud.',
        deviceLocalAccount =
            'Ricordato solo su questo dispositivo. Aggiungi una password qui sopra per un account cloud.',
        signOut = 'Esci',
        playerNameHeader = 'NOME GIOCATORE',
        playerNameLabel = 'Come il reame ti chiama',
        saveName = 'Salva nome',
        language = 'Lingua',
        moreLanguagesComing = 'altre lingue in arrivo',
        settingsFooter =
            'Le impostazioni sono salvate su questo dispositivo. L\'accesso le prepara alla sincronizzazione cloud.',
        invalidEmail = 'Inserisci un indirizzo email valido',
        shortPassword = 'Scegli una password di almeno 6 caratteri.',
        enterCode = 'Inserisci il codice dalla mail.',
        confirmationResent = 'Email di conferma inviata di nuovo.',
        cancel = 'Annulla',
        back = 'Indietro',
        continueLabel = 'Continua',
        welcomePattern = 'Benvenuto, {name}, in {app}',
        welcomeBackPattern = 'Bentornato, {name} — {app} ti aspetta',
        signedInAsPattern = 'Accesso effettuato come {email}',
        confirmationSentPattern =
            'Ti abbiamo inviato una conferma a {email}. Inserisci il codice dalla mail — o apri il suo link — per completare la registrazione.',
        stepHeaderPattern = 'Passo {step} di {total} — {title}',
        hostedHere = ' — host qui',
        claimHost = 'Diventa host',
        roomOptions = 'Opzioni stanza',
        hostOfThisRoom = 'Host di questa stanza',
        youSuffix = '(tu)',
        readyLabel = 'è pronto',
        notReadyLabel = 'non si è ancora preparato',
        passwordProtected = 'protetta da password',
        notStartedYet = 'non ancora iniziata',
        cancelHandover = 'Annulla passaggio di consegne',
        handOverHost = 'Passa l\'host',
        promoteSeatHint = 'Promuovi un posto; il mondo continua',
        deleteRoom = 'Elimina stanza',
        endsWorldHint = 'Termina il mondo per ogni posto',
        leaveRoom = 'Lascia la stanza',
        seatLeavesHint = 'Il tuo posto esce; il mondo continua',
        chooseHostBody =
            'Scegli il posto che diventa l\'host. Il mondo continua a girare; il prescelto rivendica i poteri di host dal suo dispositivo.',
        keepIt = 'Conservala',
        deleteForEveryone = 'Elimina per tutti',
        stay = 'Resta',
        leave = 'Esci',
        pendingHandovers = 'PASSAGGI DI CONSEGNE IN ATTESA',
        dialogServerTitle = 'Game server',
        serverUrlLabel = 'URL del server',
        serverUrlHint = 'es. https://games.example.org',
        anonKeyLabel = 'Chiave anon Supabase',
        anonKeyHint = 'vuota per un PostgREST puro',
        anonKeyHelper = 'VM: grep ANON_KEY env · Studio → Impostazioni → API',
        connect = 'Connetti',
        worldTitlePattern = 'Mondo {code}',
        clockStatusPattern = 'orologio {n}',
        hostHandoverPendingPattern = 'passaggio di consegne a {name} in attesa',
        acceptPromotionPattern =
            'Accetta la promozione di {name} su questo dispositivo',
        withdrawPromotionPattern = 'Ritira la promozione in attesa di {name}',
        handoverPickerTitlePattern = 'Passa il mondo {code}',
        deleteRoomTitlePattern = 'Eliminare il mondo {code}?',
        deleteRoomBodyPattern =
            'La stanza viene rimossa per ogni posto — {seats}. I loro dispositivi non conservano altro che i salvataggi locali. Non si può annullare.',
        leaveRoomTitlePattern = 'Lasciare il mondo {code}?',
        leaveRoomBodyAllPattern =
            'Il tuo posto esce e il mondo continua per {seats} — il tuo salvataggio locale resta su questo dispositivo.',
        leaveRoomBodySeatPattern =
            'Il tuo posto ({name}) è rimosso dall\'elenco. Il mondo continua per {others}.',
        directEntry = 'GIOCA',
        soloStart = 'INIZIA DA SOLO',
        addSeat = 'Aggiungi posto',
        seatsHeader = 'BANNIERI',
        joinSectionHeader = 'ENTRA IN UNA PARTITA',
        gameNumberLabel = 'Numero della partita',
        gameNumberHint = 'es. K7QX2',
        joinGame = 'ENTRA NELLA PARTITA',
        gameNumberMissing = 'Inserisci il numero della partita che ti ha condiviso l\'host.',
        gameRoomMissing =
            'Nessuna partita risponde a quel numero — verificalo con l\'host.',
        gameWrongPassword = 'Password della partita errata.',
        gameJoinFailed = 'Impossibile raggiungere il game server. Riprova.',
        joinPasswordLabel = 'Password della partita (se l\'host ne ha messa una)',
    hotSeatNote =
        'Posti sullo stesso dispositivo — passa il device tra i bannieri.',
    removeSeatTooltip = 'Rimuovi questo posto',
    youMarker = '(tu)';

  /// The catalog for [language] (unknown codes fall back to English, the
  /// same rule the persisted-locale loader applies).
  static ShellStrings forLanguage(ShellLanguage language) =>
      language == ShellLanguage.italiano
          ? const ShellStrings.italian()
          : const ShellStrings();

  // -- Top bar ------------------------------------------------------------
  final String switchThemeTooltip;
  final String settingsTooltip;

  // -- Splash -------------------------------------------------------------
  final String newGame;
  final String continueDefault;
  final String noSavedGames;

  // -- Settings screen ----------------------------------------------------
  final String settingsTitle;
  final String accountHeader;
  final String guest;
  final String checkYourInbox;
  final String verificationCodeLabel;
  final String verificationCodeHint;
  final String confirm;
  final String resendEmail;
  final String useDifferentAddress;
  final String signInPitch;
  final String emailLabel;
  final String emailHint;
  final String passwordLabel;
  final String passwordHint;
  final String signInWithEmail;
  final String serverOnboardingHint;
  final String connectGameServer;
  final String createOrSignInCloud;
  final String cloudAccountReady;
  final String deviceLocalAccount;
  final String signOut;
  final String playerNameHeader;
  final String playerNameLabel;
  final String saveName;
  final String language;
  final String moreLanguagesComing;
  final String settingsFooter;
  final String invalidEmail;
  final String shortPassword;
  final String enterCode;
  final String confirmationResent;
  final String cancel;

  // -- Lobby wizard -------------------------------------------------------
  final String back;
  final String continueLabel;

  // -- Interpolated patterns ----------------------------------------------
  // Word order differs per language, so these strings carry {tokens} the
  // methods below substitute. Keeping them as fields (not per-language
  // method overrides) is what keeps every catalog a const instance.

  /// 'Welcome, {name}, to {app}'
  final String welcomePattern;

  /// 'Welcome back, {name} — {app} awaits'
  final String welcomeBackPattern;

  /// 'Signed in as {email}'
  final String signedInAsPattern;

  /// The signup confirmation line with the {email} spelled out.
  final String confirmationSentPattern;

  /// The lobby wizard's step header: 'Step {step} of {total} — {title}'.
  final String stepHeaderPattern;

  // -- Multiplayer core ---------------------------------------------------
  final String hostedHere;
  final String claimHost;
  final String roomOptions;
  final String hostOfThisRoom;
  final String youSuffix;
  final String readyLabel;
  final String notReadyLabel;
  final String passwordProtected;
  final String notStartedYet;
  final String cancelHandover;
  final String handOverHost;
  final String promoteSeatHint;
  final String deleteRoom;
  final String endsWorldHint;
  final String leaveRoom;
  final String seatLeavesHint;
  final String chooseHostBody;
  final String keepIt;
  final String deleteForEveryone;
  final String stay;
  final String leave;
  final String pendingHandovers;
  final String dialogServerTitle;
  final String serverUrlLabel;
  final String serverUrlHint;
  final String anonKeyLabel;
  final String anonKeyHint;
  final String anonKeyHelper;
  final String connect;

  /// 'World {code}'
  final String worldTitlePattern;

  /// 'clock {n}'
  final String clockStatusPattern;

  /// 'host handover to {name} pending'
  final String hostHandoverPendingPattern;

  /// 'Accept the promotion of {name} on this device'
  final String acceptPromotionPattern;

  /// 'Withdraw the pending promotion of {name}'
  final String withdrawPromotionPattern;

  /// 'Hand over world {code}'
  final String handoverPickerTitlePattern;

  /// 'Delete world {code}?'
  final String deleteRoomTitlePattern;

  /// The delete confirmation with the seat list spelled out.
  final String deleteRoomBodyPattern;

  /// 'Leave world {code}?'
  final String leaveRoomTitlePattern;

  /// The leave warning when the departing seat is unknown.
  final String leaveRoomBodyAllPattern;

  /// The leave warning personalized with the seat name.
  final String leaveRoomBodySeatPattern;

  // -- Direct entry + shared lobby step ------------------------------------
  final String directEntry;
  final String soloStart;
  final String addSeat;
  final String seatsHeader;
  final String joinSectionHeader;
  final String gameNumberLabel;
  final String gameNumberHint;
  final String joinGame;
  final String gameNumberMissing;
  final String gameRoomMissing;
  final String gameWrongPassword;
  final String gameJoinFailed;
  final String joinPasswordLabel;
  final String hotSeatNote;

  /// Tooltip on a guest seat's remove button.
  final String removeSeatTooltip;

  /// The '(you)' marker beside the local player's seat.
  final String youMarker;

  // -- Interpolated phrasing ----------------------------------------------

  /// The splash greeting for an anonymous (or first-visit) player.
  String welcome(String name, String appName) =>
      welcomePattern.replaceAll('{name}', name).replaceAll('{app}', appName);

  /// The splash greeting for a signed-in player.
  String welcomeBack(String name, String appName) => welcomeBackPattern
      .replaceAll('{name}', name)
      .replaceAll('{app}', appName);

  /// The settings line under a signed-in address.
  String signedInAs(String email) =>
      signedInAsPattern.replaceAll('{email}', email);

  /// The signup confirmation line with the address spelled out.
  String confirmationSent(String email) =>
      confirmationSentPattern.replaceAll('{email}', email);

  /// The lobby wizard's step header.
  String stepHeader(int step, int total, String title) => stepHeaderPattern
      .replaceAll('{step}', '$step')
      .replaceAll('{total}', '$total')
      .replaceAll('{title}', title);

  // -- Multiplayer phrasing -----------------------------------------------

  /// The room card's title ('World KZ9Q2').
  String worldTitle(String code) =>
      worldTitlePattern.replaceAll('{code}', code);

  /// The local seat's chip label ('Mara (you)').
  String youName(String name) => '$name $youSuffix';

  /// The room status clock ('clock 42').
  String clockStatus(int hour) =>
      clockStatusPattern.replaceAll('{n}', '$hour');

  /// A pending host handover, as the status line shows it.
  String hostHandoverPending(String name) =>
      hostHandoverPendingPattern.replaceAll('{name}', name);

  /// The Claim button's tooltip.
  String acceptPromotion(String name) =>
      acceptPromotionPattern.replaceAll('{name}', name);

  /// The cancel-handover menu entry's subtitle.
  String withdrawPromotion(String name) =>
      withdrawPromotionPattern.replaceAll('{name}', name);

  /// The handover seat picker's title.
  String handoverPickerTitle(String code) =>
      handoverPickerTitlePattern.replaceAll('{code}', code);

  /// The delete confirmation's title.
  String deleteRoomTitle(String code) =>
      deleteRoomTitlePattern.replaceAll('{code}', code);

  /// The delete confirmation's body, with the seat list spelled out.
  String deleteRoomBody(String seats) =>
      deleteRoomBodyPattern.replaceAll('{seats}', seats);

  /// The leave confirmation's title.
  String leaveRoomTitle(String code) =>
      leaveRoomTitlePattern.replaceAll('{code}', code);

  /// The leave warning when the departing seat is unknown.
  String leaveRoomBodyAll(String seats) =>
      leaveRoomBodyAllPattern.replaceAll('{seats}', seats);

  /// The leave warning personalized with the seat name.
  String leaveRoomBodySeat(String name, String others) =>
      leaveRoomBodySeatPattern
          .replaceAll('{name}', name)
          .replaceAll('{others}', others);
}
