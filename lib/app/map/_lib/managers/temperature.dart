import 'package:collection/collection.dart';
import 'package:dpip/api/exptech.dart';
import 'package:dpip/api/model/weather/weather.dart';
import 'package:dpip/app/map/_lib/manager.dart';
import 'package:dpip/app/map/_lib/utils.dart';
import 'package:dpip/core/i18n.dart';
import 'package:dpip/core/providers.dart';
import 'package:dpip/models/data.dart';
import 'package:dpip/utils/extensions/build_context.dart';
import 'package:dpip/utils/extensions/latlng.dart';
import 'package:dpip/utils/extensions/string.dart';
import 'package:dpip/utils/geojson.dart';
import 'package:dpip/utils/log.dart';
import 'package:dpip/widgets/map/map.dart';
import 'package:dpip/widgets/sheet/morphing_sheet.dart';
import 'package:dpip/widgets/ui/loading_icon.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';

class TemperatureData {
  final double latitude;
  final double longitude;
  final double temperature;
  final String stationName;
  final String county;
  final String town;
  final String id;

  TemperatureData({
    required this.latitude,
    required this.longitude,
    required this.temperature,
    required this.stationName,
    required this.county,
    required this.town,
    required this.id,
  });
}

class TemperatureMapLayerManager extends MapLayerManager {
  TemperatureMapLayerManager(super.context, super.controller);

  final currentTemperatureTime = ValueNotifier<String?>(GlobalProviders.data.temperature.firstOrNull);
  final isLoading = ValueNotifier<bool>(false);

  Function(String)? onTimeChanged;

  Future<void> setTemperatureTime(String time) async {
    if (currentTemperatureTime.value == time || isLoading.value) return;

    isLoading.value = true;

    try {
      await remove();
      currentTemperatureTime.value = time;
      await setup();

      onTimeChanged?.call(time);

      TalkerManager.instance.info('Updated Temperature data time to "$time"');
    } catch (e, s) {
      TalkerManager.instance.error('TemperatureMapLayerManager.setTemperatureTime', e, s);
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> _focus() async {
    try {
      final location = GlobalProviders.location.coordinateNotifier.value;

      if (location.isValid) {
        await controller.animateCamera(CameraUpdate.newLatLngZoom(location, 7.4));
        TalkerManager.instance.info('Moved Camera to $location');
      } else {
        await controller.animateCamera(CameraUpdate.newLatLngZoom(DpipMap.kTaiwanCenter, 6.4));
        TalkerManager.instance.info('Moved Camera to ${DpipMap.kTaiwanCenter}');
      }
    } catch (e, s) {
      TalkerManager.instance.error('TemperatureMapLayerManager._focus', e, s);
    }
  }

  @override
  Future<void> setup() async {
    if (didSetup) return;

    try {
      if (GlobalProviders.data.temperature.isEmpty) {
        final temperatureList = (await ExpTech().getWeatherList()).reversed.toList();
        if (!context.mounted) return;

        GlobalProviders.data.setTemperature(temperatureList);
        currentTemperatureTime.value = temperatureList.first;
      }

      final time = currentTemperatureTime.value;

      if (time == null) throw Exception('Time is null');

      final sourceId = MapSourceIds.temperature(time);
      final layerId = MapLayerIds.temperature(time);

      final isSourceExists = (await controller.getSourceIds()).contains(sourceId);
      final isLayerExists = (await controller.getLayerIds()).contains(layerId);

      if (!isSourceExists) {
        late final List<WeatherStation> weatherData;

        if (GlobalProviders.data.weatherData.containsKey(time)) {
          weatherData = GlobalProviders.data.weatherData[time]!;
        } else {
          weatherData = await ExpTech().getWeather(time);
          GlobalProviders.data.setWeatherData(time, weatherData);
        }

        final features =
            weatherData
                .where((station) => station.data.air.temperature != -99)
                .map((station) => station.toFeatureBuilder())
                .toList();

        final data = GeoJsonBuilder().setFeatures(features).build();

        final properties = GeojsonSourceProperties(data: data);

        await controller.addSource(sourceId, properties);
        TalkerManager.instance.info('Added Source "$sourceId"');

        if (!context.mounted) return;
      }

      if (!isLayerExists) {
        final properties = CircleLayerProperties(
          circleRadius: [
            Expressions.interpolate,
            ['linear'],
            [Expressions.zoom],
            7,
            5,
            12,
            15,
          ],
          circleColor: [
            Expressions.interpolate,
            ['linear'],
            [Expressions.get, 'temperature'],
            -20,
            '#4d4e51',
            -10,
            '#0000FF',
            0,
            '#6495ED',
            10,
            '#95d07e',
            20,
            '#f6e78b',
            30,
            '#FF4500',
            40,
            '#8B0000',
          ],
          circleOpacity: 0.7,
          circleStrokeWidth: 0.2,
          circleStrokeColor: '#000000',
          circleStrokeOpacity: 0.7,
          visibility: visible ? 'visible' : 'none',
        );

        await controller.addLayer(sourceId, layerId, properties, belowLayerId: BaseMapLayerIds.userLocation);
        TalkerManager.instance.info('Added Layer "$layerId"');
      }

      if (isSourceExists && isLayerExists) return;

      didSetup = true;
    } catch (e, s) {
      TalkerManager.instance.error('TemperatureMapLayerManager.setup', e, s);
    }
  }

  @override
  Future<void> hide() async {
    if (!visible) return;

    final layerId = MapLayerIds.temperature(currentTemperatureTime.value);

    try {
      await controller.setLayerVisibility(layerId, false);
      TalkerManager.instance.info('Hiding Layer "$layerId"');

      visible = false;
    } catch (e, s) {
      TalkerManager.instance.error('TemperatureMapLayerManager.hide', e, s);
    }
  }

  @override
  Future<void> show() async {
    if (visible) return;

    final layerId = MapLayerIds.temperature(currentTemperatureTime.value);

    try {
      await controller.setLayerVisibility(layerId, true);
      TalkerManager.instance.info('Showing Layer "$layerId"');

      await _focus();

      visible = true;
    } catch (e, s) {
      TalkerManager.instance.error('TemperatureMapLayerManager.show', e, s);
    }
  }

  @override
  Future<void> remove() async {
    try {
      final layerId = MapLayerIds.temperature(currentTemperatureTime.value);
      final sourceId = MapSourceIds.temperature(currentTemperatureTime.value);

      await controller.removeLayer(layerId);
      TalkerManager.instance.info('Removed Layer "$layerId"');

      await controller.removeSource(sourceId);
      TalkerManager.instance.info('Removed Source "$sourceId"');
    } catch (e, s) {
      TalkerManager.instance.error('TemperatureMapLayerManager.remove', e, s);
    }

    didSetup = false;
  }

  @override
  Widget build(BuildContext context) => TemperatureMapLayerSheet(manager: this);
}

class TemperatureMapLayerSheet extends StatelessWidget {
  final TemperatureMapLayerManager manager;

  const TemperatureMapLayerSheet({super.key, required this.manager});

  @override
  Widget build(BuildContext context) {
    return MorphingSheet(
      title: '氣溫'.i18n,
      borderRadius: BorderRadius.circular(16),
      elevation: 4,
      partialBuilder: (context, controller, sheetController) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Selector<DpipDataModel, UnmodifiableListView<String>>(
            selector: (context, model) => model.temperature,
            builder: (context, temperature, header) {
              final times = temperature.map((time) {
                final t = time.toSimpleDateTimeString(context).split(' ');
                return (date: t[0], time: t[1], value: time);
              });
              final grouped = times.groupListsBy((time) => time.date).entries.toList();

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  header!,
                  SizedBox(
                    height: kMinInteractiveDimension,
                    child: ValueListenableBuilder<String?>(
                      valueListenable: manager.currentTemperatureTime,
                      builder: (context, currentTemperatureTime, child) {
                        return ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          scrollDirection: Axis.horizontal,
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: grouped.length,
                          itemBuilder: (context, index) {
                            final MapEntry(key: date, value: group) = grouped[index];

                            final children = <Widget>[Text(date)];

                            for (final time in group) {
                              final isSelected = time.value == currentTemperatureTime;

                              children.add(
                                ValueListenableBuilder<bool>(
                                  valueListenable: manager.isLoading,
                                  builder: (context, isLoading, child) {
                                    return FilterChip(
                                      selected: isSelected,
                                      showCheckmark: !isLoading,
                                      label: Text(time.time),
                                      side: BorderSide(
                                        color: isSelected ? context.colors.primary : context.colors.outlineVariant,
                                      ),
                                      avatar: isSelected && isLoading ? const LoadingIcon() : null,
                                      onSelected:
                                          isLoading
                                              ? null
                                              : (selected) {
                                                if (!selected) return;
                                                manager.setTemperatureTime(time.value);
                                              },
                                    );
                                  },
                                ),
                              );
                            }

                            children.add(
                              const Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: VerticalDivider(width: 16, indent: 8, endIndent: 8),
                              ),
                            );

                            return Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: children);
                          },
                        );
                      },
                    ),
                  ),
                ],
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                spacing: 8,
                children: [
                  const Icon(Symbols.thermostat_rounded, size: 24),
                  Text('氣溫'.i18n, style: context.textTheme.titleMedium),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
