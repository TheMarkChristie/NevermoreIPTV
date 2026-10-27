# House presets

Put a `presets.json` here to build it into the app: a code typed with the remote's number keys on Settings then sets a
source's channels in one go. The file is not in the repository (`.gitignore`): it names one household's provider and
picks. Without it the codes do nothing. The format is described in `lib/core/presets.dart`.

A preset may carry its provider login locked with the code (scrypt and AES-256-GCM; `lib/core/preset_lock.dart` opens
it, `tools/make_house_presets.py` locks it): the code is then not in the file at all, and typing it on a TV adds the
source and sets its channels in one go.
