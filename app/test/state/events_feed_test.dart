import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/docker_event.dart';
import 'package:docker_mobile/src/state/events_feed.dart';

DockerEvent ev(String type, String target) => DockerEvent(type: type, action: 'start', target: target);

void main() {
  test('adds newest first and caps the buffer', () {
    final f = EventsFeed();
    for (var i = 0; i < kEventsBufferCap + 5; i++) {
      f.add(ev('container', 'c$i'));
    }
    expect(f.state.events, hasLength(kEventsBufferCap));
    expect(f.state.events.first.target, 'c${kEventsBufferCap + 4}');
  });

  test('filters by type and clears the filter', () {
    final f = EventsFeed()
      ..add(ev('container', 'web'))
      ..add(ev('image', 'nginx'));
    f.setFilter('image');
    expect(f.state.visibleEvents.single.target, 'nginx');
    f.setFilter(null);
    expect(f.state.visibleEvents, hasLength(2));
  });

  test('clear empties the feed but keeps the filter', () {
    final f = EventsFeed()
      ..add(ev('container', 'web'))
      ..setFilter('container');
    f.clear();
    expect(f.state.events, isEmpty);
    expect(f.state.filterType, 'container');
  });
}
