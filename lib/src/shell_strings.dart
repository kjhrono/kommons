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
    this.prefTheme = 'Theme',
    this.prefLanguage = 'Language',
    this.prefPlayerName = 'Player name',
    this.prefFromAccount = 'from your account',
    this.prefFromDevice = 'from this device',
    this.prefFromDefault = 'app default',
    this.invalidEmail = 'Enter a valid email address',
    this.shortPassword = 'Choose a password of at least 6 characters.',
    this.enterCode = 'Enter the code from the email.',
    this.confirmationResent = 'Confirmation email sent again.',
    this.forgotPassword = 'Forgot password?',
    this.resetTitle = 'RESET PASSWORD',
    this.resetSentPattern =
        'If an account exists for {email}, a reset email is on its way. Enter the code it carries — or open its link — to sign back in.',
    this.resetCodeLabel = 'Reset code',
    this.resetCodeHint = 'the code from the reset email',
    this.resendReset = 'Resend reset email',
    this.cancelReset = 'Cancel',
    this.resetEmailSent = 'Reset email sent.',
    this.changePassword = 'Change password',
    this.changePasswordHint =
        'You are signed in with a temporary password. Choose a new one to finish recovering your account.',
    this.recoveryLinkCompleted =
        'Signed back in. Pick a new password to finish recovering your account.',
    this.changePasswordSectionHint = 'Pick a new password for your account.',
    this.currentPasswordLabel = 'Current password',
    this.enterCurrentPassword = 'Enter your current password first.',
    this.newPasswordLabel = 'New password',
    this.newPasswordHint = '6+ characters',
    this.newPasswordConfirmLabel = 'Repeat the new password',
    this.passwordMismatch = 'The two passwords do not match.',
    this.passwordChanged = 'Password changed.',
    this.passwordChangeFailed = 'Could not change the password',
    this.cancel = 'Cancel',
    this.notNow = 'Not now',
    this.preferencesSynced = 'Preferences loaded from your account',
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
    this.inviteHeader = 'Invite',
    this.inviteLinkLabel = 'Invite link',
    this.inviteLinkHint =
        'Send it to your players — opening it opens this lobby with the number filled in.',
    this.inviteCopy = 'Copy link',
    this.inviteCopied = 'Link copied — send it to your players.',
    this.inviteSendEmail = 'Send by email',
    this.inviteQrHint =
        'Phone players can scan this to join — no copying, no typing.',
    this.inviteShare = 'Share the QR',
    this.inviteQrSharedPattern = 'QR shared — players scan it to join {code}.',
    this.invitePaste = 'Paste a link you were sent',
    this.invitePastedJoin = 'Invite found — join as {name}?',
    this.inviteNothingToPaste = 'Nothing to paste — copy an invite link first.',
    this.inviteJoinedWith = 'Invited as {name} — number locked in.',
  });

  /// The Italian catalog. Word order and idiom follow Italian, not the
  /// English source — the {token} patterns below carry their own phrasing.
  const ShellStrings.italian(
      {String? code,
      String? nativeName,
      String? switchThemeTooltip,
      String? settingsTooltip,
      String? newGame,
      String? continueDefault,
      String? noSavedGames,
      String? settingsTitle,
      String? accountHeader,
      String? guest,
      String? checkYourInbox,
      String? verificationCodeLabel,
      String? verificationCodeHint,
      String? confirm,
      String? resendEmail,
      String? useDifferentAddress,
      String? signInPitch,
      String? emailLabel,
      String? emailHint,
      String? passwordLabel,
      String? passwordHint,
      String? signInWithEmail,
      String? serverOnboardingHint,
      String? connectGameServer,
      String? createOrSignInCloud,
      String? cloudAccountReady,
      String? deviceLocalAccount,
      String? signOut,
      String? playerNameHeader,
      String? playerNameLabel,
      String? saveName,
      String? language,
      String? moreLanguagesComing,
      String? settingsFooter,
      String? prefTheme,
      String? prefLanguage,
      String? prefPlayerName,
      String? prefFromAccount,
      String? prefFromDevice,
      String? prefFromDefault,
      String? invalidEmail,
      String? shortPassword,
      String? enterCode,
      String? confirmationResent,
      String? forgotPassword,
      String? resetTitle,
      String? resetSentPattern,
      String? resetCodeLabel,
      String? resetCodeHint,
      String? resendReset,
      String? cancelReset,
      String? resetEmailSent,
      String? changePassword,
      String? changePasswordHint,
      String? recoveryLinkCompleted,
      String? changePasswordSectionHint,
      String? currentPasswordLabel,
      String? enterCurrentPassword,
      String? newPasswordLabel,
      String? newPasswordHint,
      String? newPasswordConfirmLabel,
      String? passwordMismatch,
      String? passwordChanged,
      String? passwordChangeFailed,
      String? cancel,
      String? notNow,
      String? preferencesSynced,
      String? back,
      String? continueLabel,
      String? welcomePattern,
      String? welcomeBackPattern,
      String? signedInAsPattern,
      String? confirmationSentPattern,
      String? stepHeaderPattern,
      String? hostedHere,
      String? claimHost,
      String? roomOptions,
      String? hostOfThisRoom,
      String? youSuffix,
      String? readyLabel,
      String? notReadyLabel,
      String? passwordProtected,
      String? notStartedYet,
      String? cancelHandover,
      String? handOverHost,
      String? promoteSeatHint,
      String? deleteRoom,
      String? endsWorldHint,
      String? leaveRoom,
      String? seatLeavesHint,
      String? chooseHostBody,
      String? keepIt,
      String? deleteForEveryone,
      String? stay,
      String? leave,
      String? pendingHandovers,
      String? dialogServerTitle,
      String? serverUrlLabel,
      String? serverUrlHint,
      String? anonKeyLabel,
      String? anonKeyHint,
      String? anonKeyHelper,
      String? connect,
      String? worldTitlePattern,
      String? clockStatusPattern,
      String? hostHandoverPendingPattern,
      String? acceptPromotionPattern,
      String? withdrawPromotionPattern,
      String? handoverPickerTitlePattern,
      String? deleteRoomTitlePattern,
      String? deleteRoomBodyPattern,
      String? leaveRoomTitlePattern,
      String? leaveRoomBodyAllPattern,
      String? leaveRoomBodySeatPattern,
      String? directEntry,
      String? soloStart,
      String? addSeat,
      String? seatsHeader,
      String? joinSectionHeader,
      String? gameNumberLabel,
      String? gameNumberHint,
      String? joinGame,
      String? gameNumberMissing,
      String? gameRoomMissing,
      String? gameWrongPassword,
      String? gameJoinFailed,
      String? joinPasswordLabel,
      String? hotSeatNote,
      String? removeSeatTooltip,
      String? youMarker,
      String? inviteHeader,
      String? inviteLinkLabel,
      String? inviteLinkHint,
      String? inviteCopy,
      String? inviteCopied,
      String? inviteSendEmail,
      String? inviteQrHint,
      String? inviteShare,
      String? inviteQrSharedPattern,
      String? invitePaste,
      String? invitePastedJoin,
      String? inviteNothingToPaste,
      String? inviteJoinedWith})
      : switchThemeTooltip = switchThemeTooltip ?? 'Cambia tema giorno/notte',
        settingsTooltip = settingsTooltip ?? 'Impostazioni',
        newGame = newGame ?? 'NUOVA PARTITA',
        continueDefault = continueDefault ?? 'CONTINUA',
        noSavedGames = noSavedGames ?? 'NESSUNA PARTITA SALVATA',
        settingsTitle = settingsTitle ?? 'IMPOSTAZIONI',
        accountHeader = accountHeader ?? 'ACCOUNT',
        guest = guest ?? 'Ospite',
        checkYourInbox = checkYourInbox ?? 'CONTROLLA LA TUA EMAIL',
        verificationCodeLabel = verificationCodeLabel ?? 'Codice di verifica',
        verificationCodeHint = verificationCodeHint ?? 'le 6 cifre della mail',
        confirm = confirm ?? 'Conferma',
        resendEmail = resendEmail ?? 'Reinvia email',
        useDifferentAddress = useDifferentAddress ?? 'Usa un altro indirizzo',
        signInPitch =
            'Accedi per conservare nome, salvataggi e partite condivise sul cloud. Prima la email; gli altri provider potranno unirsi più avanti.',
        emailLabel = emailLabel ?? 'Email',
        emailHint = emailHint ?? 'tu@esempio.com',
        passwordLabel = passwordLabel ?? 'Password (account cloud)',
        passwordHint = passwordHint ?? '6+ caratteri — registra al primo uso',
        signInWithEmail = signInWithEmail ?? 'Accedi con email',
        serverOnboardingHint =
            'Gli account cloud si registrano sul tuo game server — connettilo una volta qui sotto (la stessa connessione che usa il multiplayer online).',
        connectGameServer = connectGameServer ?? 'Connetti game server',
        createOrSignInCloud =
            createOrSignInCloud ?? 'Crea / accedi all\'account cloud',
        cloudAccountReady =
            'Account cloud — verificato dal tuo game server, pronto per i salvataggi sul cloud.',
        deviceLocalAccount =
            'Ricordato solo su questo dispositivo. Aggiungi una password qui sopra per un account cloud.',
        signOut = signOut ?? 'Esci',
        playerNameHeader = playerNameHeader ?? 'NOME GIOCATORE',
        playerNameLabel = playerNameLabel ?? 'Come il reame ti chiama',
        saveName = saveName ?? 'Salva nome',
        language = language ?? 'Lingua',
        moreLanguagesComing = moreLanguagesComing ?? 'altre lingue in arrivo',
        settingsFooter =
            'Le impostazioni sono salvate su questo dispositivo. L\'accesso le prepara alla sincronizzazione cloud.',
        prefTheme = prefTheme ?? 'Tema',
        prefLanguage = prefLanguage ?? 'Lingua',
        prefPlayerName = prefPlayerName ?? 'Nome giocatore',
        prefFromAccount = prefFromAccount ?? 'dal tuo account',
        prefFromDevice = prefFromDevice ?? 'da questo dispositivo',
        prefFromDefault = prefFromDefault ?? 'predefinito dell\'app',
        invalidEmail = invalidEmail ?? 'Inserisci un indirizzo email valido',
        shortPassword =
            shortPassword ?? 'Scegli una password di almeno 6 caratteri.',
        enterCode = enterCode ?? 'Inserisci il codice dalla mail.',
        confirmationResent =
            confirmationResent ?? 'Email di conferma inviata di nuovo.',
        forgotPassword = forgotPassword ?? 'Password dimenticata?',
        resetTitle = resetTitle ?? 'REIMPOSTA PASSWORD',
        resetSentPattern =
            'Se esiste un account per {email}, la email di reset è in arrivo. Inserisci il codice che contiene — o apri il suo link — per rientrare.',
        resetCodeLabel = resetCodeLabel ?? 'Codice di reset',
        resetCodeHint = resetCodeHint ?? 'il codice dalla email di reset',
        resendReset = resendReset ?? 'Reinvia la email di reset',
        cancelReset = cancelReset ?? 'Annulla',
        resetEmailSent = resetEmailSent ?? 'Email di reset inviata.',
        changePassword = changePassword ?? 'Cambia password',
        changePasswordHint =
            'Sei dentro con una password temporanea. Scegline una nuova per completare il recupero dell\'account.',
        recoveryLinkCompleted =
            'Accesso riuscito. Scegli una nuova password per completare il recupero dell\'account.',
        changePasswordSectionHint =
            'Scegli una nuova password per il tuo account.',
        currentPasswordLabel = currentPasswordLabel ?? 'Password attuale',
        enterCurrentPassword =
            enterCurrentPassword ?? 'Inserisci prima la password attuale.',
        newPasswordLabel = newPasswordLabel ?? 'Nuova password',
        newPasswordHint = newPasswordHint ?? '6+ caratteri',
        newPasswordConfirmLabel =
            newPasswordConfirmLabel ?? 'Ripeti la nuova password',
        passwordMismatch =
            passwordMismatch ?? 'Le due password non coincidono.',
        passwordChanged = passwordChanged ?? 'Password cambiata.',
        passwordChangeFailed =
            passwordChangeFailed ?? 'Impossibile cambiare la password',
        cancel = cancel ?? 'Annulla',
        notNow = notNow ?? 'Non ora',
        preferencesSynced =
            preferencesSynced ?? 'Preferenze caricate dal tuo account',
        back = back ?? 'Indietro',
        continueLabel = continueLabel ?? 'Continua',
        welcomePattern = welcomePattern ?? 'Benvenuto, {name}, in {app}',
        welcomeBackPattern =
            welcomeBackPattern ?? 'Bentornato, {name} — {app} ti aspetta',
        signedInAsPattern =
            signedInAsPattern ?? 'Accesso effettuato come {email}',
        confirmationSentPattern =
            'Ti abbiamo inviato una conferma a {email}. Inserisci il codice dalla mail — o apri il suo link — per completare la registrazione.',
        stepHeaderPattern =
            stepHeaderPattern ?? 'Passo {step} di {total} — {title}',
        hostedHere = hostedHere ?? ' — host qui',
        claimHost = claimHost ?? 'Diventa host',
        roomOptions = roomOptions ?? 'Opzioni stanza',
        hostOfThisRoom = hostOfThisRoom ?? 'Host di questa stanza',
        youSuffix = youSuffix ?? '(tu)',
        readyLabel = readyLabel ?? 'è pronto',
        notReadyLabel = notReadyLabel ?? 'non si è ancora preparato',
        passwordProtected = passwordProtected ?? 'protetta da password',
        notStartedYet = notStartedYet ?? 'non ancora iniziata',
        cancelHandover = cancelHandover ?? 'Annulla passaggio di consegne',
        handOverHost = handOverHost ?? 'Passa l\'host',
        promoteSeatHint =
            promoteSeatHint ?? 'Promuovi un posto; il mondo continua',
        deleteRoom = deleteRoom ?? 'Elimina stanza',
        endsWorldHint = endsWorldHint ?? 'Termina il mondo per ogni posto',
        leaveRoom = leaveRoom ?? 'Lascia la stanza',
        seatLeavesHint =
            seatLeavesHint ?? 'Il tuo posto esce; il mondo continua',
        chooseHostBody =
            'Scegli il posto che diventa l\'host. Il mondo continua a girare; il prescelto rivendica i poteri di host dal suo dispositivo.',
        keepIt = keepIt ?? 'Conservala',
        deleteForEveryone = deleteForEveryone ?? 'Elimina per tutti',
        stay = stay ?? 'Resta',
        leave = leave ?? 'Esci',
        pendingHandovers = pendingHandovers ?? 'PASSAGGI DI CONSEGNE IN ATTESA',
        dialogServerTitle = dialogServerTitle ?? 'Game server',
        serverUrlLabel = serverUrlLabel ?? 'URL del server',
        serverUrlHint = serverUrlHint ?? 'es. https://games.example.org',
        anonKeyLabel = anonKeyLabel ?? 'Chiave anon Supabase',
        anonKeyHint = anonKeyHint ?? 'vuota per un PostgREST puro',
        anonKeyHelper = anonKeyHelper ??
            'VM: grep ANON_KEY env · Studio → Impostazioni → API',
        connect = connect ?? 'Connetti',
        worldTitlePattern = worldTitlePattern ?? 'Mondo {code}',
        clockStatusPattern = clockStatusPattern ?? 'orologio {n}',
        hostHandoverPendingPattern = hostHandoverPendingPattern ??
            'passaggio di consegne a {name} in attesa',
        acceptPromotionPattern =
            'Accetta la promozione di {name} su questo dispositivo',
        withdrawPromotionPattern = withdrawPromotionPattern ??
            'Ritira la promozione in attesa di {name}',
        handoverPickerTitlePattern =
            handoverPickerTitlePattern ?? 'Passa il mondo {code}',
        deleteRoomTitlePattern =
            deleteRoomTitlePattern ?? 'Eliminare il mondo {code}?',
        deleteRoomBodyPattern =
            'La stanza viene rimossa per ogni posto — {seats}. I loro dispositivi non conservano altro che i salvataggi locali. Non si può annullare.',
        leaveRoomTitlePattern =
            leaveRoomTitlePattern ?? 'Lasciare il mondo {code}?',
        leaveRoomBodyAllPattern =
            'Il tuo posto esce e il mondo continua per {seats} — il tuo salvataggio locale resta su questo dispositivo.',
        leaveRoomBodySeatPattern =
            'Il tuo posto ({name}) è rimosso dall\'elenco. Il mondo continua per {others}.',
        directEntry = directEntry ?? 'GIOCA',
        soloStart = soloStart ?? 'INIZIA DA SOLO',
        addSeat = addSeat ?? 'Aggiungi posto',
        seatsHeader = seatsHeader ?? 'BANNIERI',
        joinSectionHeader = joinSectionHeader ?? 'ENTRA IN UNA PARTITA',
        gameNumberLabel = gameNumberLabel ?? 'Numero della partita',
        gameNumberHint = gameNumberHint ?? 'es. K7QX2',
        joinGame = joinGame ?? 'ENTRA NELLA PARTITA',
        gameNumberMissing =
            'Inserisci il numero della partita che ti ha condiviso l\'host.',
        gameRoomMissing =
            'Nessuna partita risponde a quel numero — verificalo con l\'host.',
        gameWrongPassword =
            gameWrongPassword ?? 'Password della partita errata.',
        gameJoinFailed = gameJoinFailed ??
            'Impossibile raggiungere il game server. Riprova.',
        joinPasswordLabel =
            'Password della partita (se l\'host ne ha messa una)',
        hotSeatNote =
            'Posti sullo stesso dispositivo — passa il device tra i bannieri.',
        removeSeatTooltip = removeSeatTooltip ?? 'Rimuovi questo posto',
        youMarker = youMarker ?? '(tu)',
        inviteHeader = inviteHeader ?? 'Invita',
        inviteLinkLabel = inviteLinkLabel ?? 'Link di invito',
        inviteLinkHint =
            'Invialo ai tuoi giocatori: aprirlo apre questa lobby con il numero già inserito.',
        inviteCopy = inviteCopy ?? 'Copia link',
        inviteCopied =
            inviteCopied ?? 'Link copiato — invialo ai tuoi giocatori.',
        inviteSendEmail = inviteSendEmail ?? 'Invia per email',
        inviteQrHint =
            'Chi gioca da telefono può scansionarlo per entrare: niente copia, niente digitazione.',
        inviteShare = inviteShare ?? 'Condividi il QR',
        inviteQrSharedPattern = inviteQrSharedPattern ??
            'QR condiviso — i giocatori lo scansionano per entrare ({code}).',
        invitePaste = invitePaste ?? 'Incolla un link che ti è stato inviato',
        invitePastedJoin =
            invitePastedJoin ?? 'Invito trovato — entrare come {name}?',
        inviteNothingToPaste =
            'Niente da incollare: copia prima un link di invito.',
        inviteJoinedWith =
            inviteJoinedWith ?? 'Invitato come {name} — numero già inserito.';

  /// The catalog for [language] (unknown codes fall back to English, the
  /// same rule the persisted-locale loader applies). A host-installed
  /// override (see [installOverrides]) wins over the built-in catalog.
  static ShellStrings forLanguage(ShellLanguage language) {
    final override = _overrides[language];
    if (override != null) return override;
    return language == ShellLanguage.italiano
        ? const ShellStrings.italian()
        : const ShellStrings();
  }

  /// Host-installed catalog overrides, keyed by language.
  static final Map<ShellLanguage, ShellStrings> _overrides = {};

  /// Replaces what the shell says in [language] with [strings] — most
  /// usefully a *partial* instance. Every field of the constructors has a
  /// default, so one line overrides one string and keeps the rest of the
  /// language's wording:
  ///
  /// ```dart
  /// ShellStrings.installOverrides({
  ///   ShellLanguage.english: const ShellStrings(
  ///       preferencesSynced: 'Your look, language and name just synced.'),
  ///   ShellLanguage.italiano: const ShellStrings.italian(
  ///       preferencesSynced: 'Aspetto, lingua e nome sono arrivati dal cloud.'),
  /// });
  /// ```
  ///
  /// Reads happen per frame through [AppLocaleNotifier.strings], so calls
  /// land as soon as they run — but installing before `runApp` is the
  /// dependable spot. Call [resetOverrides] to go back to the built-in
  /// catalogs (tests do this in their setup).
  static void installOverrides(Map<ShellLanguage, ShellStrings> catalogs) {
    _overrides.addAll(catalogs);
  }

  /// Forgets every host override (see [installOverrides]).
  static void resetOverrides() => _overrides.clear();

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
  final String prefTheme;
  final String prefLanguage;
  final String prefPlayerName;
  final String prefFromAccount;
  final String prefFromDevice;
  final String prefFromDefault;
  final String invalidEmail;
  final String shortPassword;
  final String enterCode;
  final String confirmationResent;

  // -- Password reset + change --------------------------------------------
  final String forgotPassword;
  final String resetTitle;
  final String resetSentPattern;
  final String resetCodeLabel;
  final String resetCodeHint;
  final String resendReset;
  final String cancelReset;
  final String resetEmailSent;
  final String changePassword;
  final String changePasswordHint;

  /// Shown when a recovery link (or code) completes: the player is back
  /// in, but must pick a new password to finish.
  final String recoveryLinkCompleted;
  final String changePasswordSectionHint;
  final String currentPasswordLabel;
  final String enterCurrentPassword;
  final String newPasswordLabel;
  final String newPasswordHint;
  final String newPasswordConfirmLabel;
  final String passwordMismatch;
  final String passwordChanged;
  final String passwordChangeFailed;
  final String cancel;
  final String notNow;

  /// Shown when a sign-in pulls cloud preferences in (theme, language,
  /// name): the cross-project sync made itself visible.
  final String preferencesSynced;

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
  final String inviteHeader;
  final String inviteLinkLabel;
  final String inviteLinkHint;
  final String inviteCopy;
  final String inviteCopied;
  final String inviteSendEmail;

  /// Caption under the lobby's invite QR code.
  final String inviteQrHint;

  /// Confirmation after the invite QR image was shared successfully.
  final String inviteQrSharedPattern;

  String inviteQrShared(String code) =>
      inviteQrSharedPattern.replaceAll('{code}', code);

  final String inviteShare;
  final String invitePaste;
  final String invitePastedJoin;
  final String inviteNothingToPaste;
  final String inviteJoinedWith;

  /// The confirm dialog asking the pasted/received invite's player to
  /// take the seat as their persisted persona: 'Invito trovato — entrare
  /// come {name}?' → the name substituted.
  String invitePastedJoinAs(String name) =>
      invitePastedJoin.replaceAll('{name}', name);

  /// The snackbar once a received invite is accepted:
  /// 'Invitato come {name} — numero già inserito.' → the name substituted.
  String inviteJoinedAs(String name) =>
      inviteJoinedWith.replaceAll('{name}', name);

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

  /// The reset-email-sent line with the address spelled out.
  String resetSent(String email) =>
      resetSentPattern.replaceAll('{email}', email);

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
  String clockStatus(int hour) => clockStatusPattern.replaceAll('{n}', '$hour');

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
