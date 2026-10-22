// What every install starts with. Run: flutter test
import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/defaults.dart';

void main() {
  test('Free-TV is added once, and not twice', () {
    expect(needsFreeTv(addedBefore: false, sourceUrls: const []), isTrue);
    expect(needsFreeTv(addedBefore: false, sourceUrls: const ['http://provider:8080']), isTrue);
    expect(needsFreeTv(addedBefore: false, sourceUrls: const [freeTvUrl]), isFalse); // set up before: already there
    expect(needsFreeTv(addedBefore: true, sourceUrls: const []), isFalse); // removed by hand: stays removed
  });

  test('ticked to start: the five, and the TV\'s own country', () {
    expect(defaultFreeTvGroups('nb_NO'), freeTvGroups);
    expect(defaultFreeTvGroups('en_GB'), freeTvGroups);
    expect(defaultFreeTvGroups('de_DE'), [...freeTvGroups, 'Germany']);
    expect(defaultFreeTvGroups('en-US'), [...freeTvGroups, 'USA']);
    expect(defaultFreeTvGroups('xx'), freeTvGroups);
  });
}
