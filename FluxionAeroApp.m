classdef FluxionAeroApp < matlab.apps.AppBase

    properties (Access = public)
        UIFigure          matlab.ui.Figure
        TabGroup          matlab.ui.container.TabGroup

       % Dropdowns tab 1
        Tab1                matlab.ui.container.Tab
        ShapeDropDown       matlab.ui.control.DropDown
        LengthDropDown      matlab.ui.control.DropDown
        PitchDropDown       matlab.ui.control.DropDown
        SpeedDropDown       matlab.ui.control.DropDown
        SelectedFanLabel    matlab.ui.control.Label
        FanInfoTextArea     matlab.ui.control.TextArea

        % Performance tab 2
        Tab2                matlab.ui.container.Tab
        PowerAxes           matlab.ui.control.UIAxes
        EfficiencyAxes      matlab.ui.control.UIAxes

        % tab 3 temperature + airflow
        Tab3                matlab.ui.container.Tab
        TempLamp            matlab.ui.control.Lamp
        TempLampLabel       matlab.ui.control.Label
        TempValueLabel      matlab.ui.control.Label
        HeatmapMetricSwitch matlab.ui.control.Switch
        HeatmapAxes         matlab.ui.control.UIAxes

        % ---- Tab 4: Summary & Recommendation ----
        Tab4                matlab.ui.container.Tab
        SummaryTextArea     matlab.ui.control.TextArea
        RecommendationLabel matlab.ui.control.Label
        RecomputeButton     matlab.ui.control.Button
    end

    properties (Access = private)
        % loading raw data given by NVB 
        FanDesigns          struct
        TestRuns             struct
        SensorLocations      struct
        AirVelocity          struct
        Temperature          struct
        RotationSpeed        struct
        PowerConsumption     struct

        % ---- Comfort thresholds (deg C) ----
        % These were chosen by looking at the actual temperature data:
        % every test run in this dataset averages between about 25.0C
        % and 26.0C, so the "optimal" band below is set inside that
        % real range (instead of the original 26-27.8C target, which
        % no test run in this dataset ever reaches).
        OptimalLowC  double = 25.4
        OptimalHighC double = 25.8
        YellowBandC  double = 0.25   % +/- this far outside optimal = yellow

        % Default selected fan
        CurrentFanID   string = "F01"
        CurrentTestID  string = "T001"
    end

    methods (Access = private)

        function loadAllData(app)
            % Load every .mat file's and stores it into variables
       
            dataFolder = fileparts(mfilename('fullpath'));

            s = load(fullfile(dataFolder, 'fan_design_metadata.mat'));
            app.FanDesigns = s.fan_designs;

            s = load(fullfile(dataFolder, 'fan_test_runs.mat'));
            app.TestRuns = s.test_runs;

            s = load(fullfile(dataFolder, 'fan_sensor_locations.mat'));
            app.SensorLocations = s.sensor_locations;

            s = load(fullfile(dataFolder, 'fan_air_velocity.mat'));
            app.AirVelocity = s.air_velocity;

            s = load(fullfile(dataFolder, 'fan_temperature.mat'));
            app.Temperature = s.temperature;

            s = load(fullfile(dataFolder, 'fan_rotation_speed.mat'));
            app.RotationSpeed = s.rotation_speed;

            s = load(fullfile(dataFolder, 'fan_power_consumption.mat'));
            app.PowerConsumption = s.power_consumption;
        end

        function fanID = resolveFanID(app, shape, len, pitch)
            % This function collects data from the drop down, regarding 
            % length, pitch, shape, and to locate what fan ID it uses.

            fd = app.FanDesigns;
            mask = strcmp(fd.blade_shape, shape) & ...
                   strcmp(fd.blade_length, len) & ...
                   strcmp(fd.pitch_angle, pitch);
            idx = find(mask, 1);
            % this is a safety in case no fans are found
            if isempty(idx)
                error('FluxionAeroApp:NoMatch', ...
                    'No fan design matches shape=%s length=%s pitch=%s', ...
                    shape, len, pitch);
            end
            fanID = string(fd.fan_id{idx});
        end

        function testID = resolveTestID(app, fanID, speed)
            % given a fan ID and a speed, finds the one test run that
            % used that exact fan at that exact speed.
            tr = app.TestRuns;
            mask = strcmp(tr.fan_id, fanID) & strcmp(tr.speed_setting, speed);
            idx = find(mask, 1);
            if isempty(idx)
                error('FluxionAeroApp:NoTestRun', ...
                    'No test run for fan_id=%s speed=%s', fanID, speed);
            end
            testID = string(tr.test_id{idx});
        end

        function updateSelection(app)
            % run every time a dropdown changes. Every tab is then
            % updated based of selection
            shape = app.ShapeDropDown.Value;
            len   = app.LengthDropDown.Value;
            pitch = app.PitchDropDown.Value;
            speed = app.SpeedDropDown.Value;

            try
                fanID = app.resolveFanID(shape, len, pitch);
                testID = app.resolveTestID(fanID, speed);
            catch ME
                % The uialert is in case the app decides to crash, a 
                % will pop up
                uialert(app.UIFigure, ME.message, 'Selection Error');
                return;
            end

            app.CurrentFanID = fanID;
            app.CurrentTestID = testID;

            app.refreshFanInfo();
            app.refreshPerformanceGraphs();
            app.refreshTemperatureLamp();
            app.refreshHeatmap();
            app.refreshSummary();
        end

        function refreshFanInfo(app)
            % prints out the information of the current fan selected
            % which in turn 
            fd = app.FanDesigns;
            idx = find(strcmp(fd.fan_id, app.CurrentFanID), 1);

            app.SelectedFanLabel.Text = sprintf('Selected Fan: %s (%s)', ...
                app.CurrentFanID, fd.design_label{idx});

            info = "Design ID: " + fd.fan_id{idx} + newline;
            info = info + "Design Label: " + fd.design_label{idx} + newline;
            info = info + "Blade Shape: " + fd.blade_shape{idx} + newline;
            info = info + "Blade Length: " + fd.blade_length{idx} + " (" + fd.blade_length_m(idx) + " m)" + newline;
            info = info + "Pitch Angle: " + fd.pitch_angle{idx} + " (" + fd.pitch_angle_deg(idx) + " deg)" + newline;
            info = info + "Blade Count: " + fd.blade_count(idx) + newline;
            info = info + "Test Run: " + app.CurrentTestID + " (speed = " + app.SpeedDropDown.Value + ")";
    
            app.FanInfoTextArea.Value = char(info);
        end

        function [speeds, powerAvg, effAvg] = computePerformanceCurve(app, fanID)
            % For a given fan_id, compute average power  and a simple
            % efficiency metric (air velo/watt) at each of
            % the 3 speed settings, using that fan's 3 test runs.
            tr = app.TestRuns;
            speedsOrder = ["low", "medium", "high"];
            speeds = speedsOrder;
            powerAvg = nan(1,3);
            effAvg = nan(1,3);

            % Loop once per speed (low, medium, high) and compute that
            % speed's average power and average air speed.
            for k = 1:numel(speedsOrder)
                mask = strcmp(tr.fan_id, fanID) & strcmp(tr.speed_setting, speedsOrder(k));
                idx = find(mask, 1);
                if isempty(idx)
                    continue;
                end
                tID = tr.test_id{idx};

                % "omitnan" helps in case theirs any NAN values in the 
                % data set
                pMask = strcmp(app.PowerConsumption.test_id, tID);
                meanPower = mean(app.PowerConsumption.power_W(pMask), 'omitnan');
                powerAvg(k) = meanPower;

                vMask = strcmp(app.AirVelocity.test_id, tID);
                meanAirSpeed = mean(app.AirVelocity.air_speed_mps(vMask), 'omitnan');

                if meanPower > 0
                    % means theirs more (air velocity/ watt)
                    effAvg(k) = meanAirSpeed / meanPower;
                else
                    effAvg(k) = NaN;
                end
            end
        end

        function refreshPerformanceGraphs(app)
            % creates two bar charts (Power vs Speed and
            % Efficiency vs Speed) for the currently selected fan.
            [speeds, powerAvg, effAvg] = app.computePerformanceCurve(app.CurrentFanID);
            xPos = 1:numel(speeds);


            % power v speed 
            cla(app.PowerAxes);
            bar(app.PowerAxes, xPos, powerAvg, 'FaceColor', [0.20 0.55 0.45]);
            app.PowerAxes.XTick = xPos;
            app.PowerAxes.XTickLabel = speeds;
            xlabel(app.PowerAxes, 'Speed Setting');
            ylabel(app.PowerAxes, 'Average Power (W)');
            title(app.PowerAxes, sprintf('Power vs Speed \x2013 %s', app.CurrentFanID));
            grid(app.PowerAxes, 'on');

            % efficiency v speed 
            cla(app.EfficiencyAxes);
            bar(app.EfficiencyAxes, xPos, effAvg, 'FaceColor', [0.25 0.45 0.75]);
            app.EfficiencyAxes.XTick = xPos;
            app.EfficiencyAxes.XTickLabel = speeds;
            xlabel(app.EfficiencyAxes, 'Speed Setting');
            ylabel(app.EfficiencyAxes, 'Efficiency (m/s per W)');
            title(app.EfficiencyAxes, sprintf('Efficiency vs Speed \x2013 %s', app.CurrentFanID));
            grid(app.EfficiencyAxes, 'on');
        end

        function avgTemp = currentAverageTemp(app)
            % gathers the mean temperature for lamp functionality 
            mask = strcmp(app.Temperature.test_id, app.CurrentTestID);
            avgTemp = mean(app.Temperature.temperature_C(mask), 'omitnan');
        end

        function refreshTemperatureLamp(app)
            % Sets the tab 3 lamp to green, yellow, or red by comparing
            % the average temperature to the comfort thresholds above.
            avgTemp = app.currentAverageTemp();
            app.TempValueLabel.Text = sprintf('Average Room Temperature: %.2f C (%.1f F)', ...
                avgTemp, avgTemp*9/5 + 32);

            if avgTemp >= app.OptimalLowC && avgTemp <= app.OptimalHighC
                app.TempLamp.Color = [0.20 0.70 0.20];   % green
                status = 'On Target';
            elseif (avgTemp > app.OptimalHighC && avgTemp <= app.OptimalHighC + app.YellowBandC) || ...
                   (avgTemp < app.OptimalLowC && avgTemp >= app.OptimalLowC - app.YellowBandC)
                app.TempLamp.Color = [0.95 0.75 0.10];   % yellow
                status = 'Close to Target';
            else
                app.TempLamp.Color = [0.85 0.20 0.20];   % red
                status = 'Off Target';
            end
            app.TempLampLabel.Text = sprintf('Temperature Status: %s', status);
        end

        function refreshHeatmap(app)
            % Heatmap that displays the sensors that helps find the 
            % average air speed or average temperature at each point 
            % the gird

       

            metric = app.HeatmapMetricSwitch.Value; % 'Air Speed' or 'Temperature'
            loc = app.SensorLocations;
            nLoc = numel(loc.location_id);

            values = nan(nLoc, 1);
            if strcmp(metric, 'Air Speed')
                mask = strcmp(app.AirVelocity.test_id, app.CurrentTestID);
                testLocIDs = app.AirVelocity.location_id(mask);
                testVals   = app.AirVelocity.air_speed_mps(mask);
                unitLabel = 'Air Speed (m/s)';
            else
                mask = strcmp(app.Temperature.test_id, app.CurrentTestID);
                testLocIDs = app.Temperature.location_id(mask);
                testVals   = app.Temperature.temperature_C(mask);
                unitLabel = 'Temperature (C)';
            end

            % For each of the 35 sensor spots, average all its readings
            % from this test run into one number.
            for i = 1:nLoc
                locMask = strcmp(testLocIDs, loc.location_id{i});
                v = testVals(locMask);
                if ~isempty(v)
                    values(i) = mean(v, 'omitnan');
                end
            end

            % Grid is 7 columns x 5 rows across a 10m x 8m room

            % Assisted by Claude to help figure out how to properly display the 
            % 10m x 8m room onto a heatmap 
            xUnique = unique(loc.x_m);
            yUnique = unique(loc.y_m);
            nx = numel(xUnique);
            ny = numel(yUnique);
            Z = nan(ny, nx);
            for i = 1:nLoc
                col = find(xUnique == loc.x_m(i), 1);
                row = find(yUnique == loc.y_m(i), 1);
                Z(row, col) = values(i);
            end

            cla(app.HeatmapAxes);
            imagesc(app.HeatmapAxes, xUnique, yUnique, Z);
            set(app.HeatmapAxes, 'YDir', 'normal');
            colormap(app.HeatmapAxes, 'turbo');
            cb = colorbar(app.HeatmapAxes);
            cb.Label.String = unitLabel;
            xlabel(app.HeatmapAxes, 'Room X (m)');
            ylabel(app.HeatmapAxes, 'Room Y (m)');
            title(app.HeatmapAxes, sprintf('%s Heatmap \x2013 %s', metric, app.CurrentFanID));
            axis(app.HeatmapAxes, 'equal');
            xlim(app.HeatmapAxes, [0 10]);
            ylim(app.HeatmapAxes, [0 8]);

            hold(app.HeatmapAxes, 'on');
            plot(app.HeatmapAxes, 5, 4, 'wp', 'MarkerSize', 14, 'MarkerFaceColor', 'k');
            text(app.HeatmapAxes, 5.2, 4, 'Fan', 'Color', 'w', 'FontWeight', 'bold');
            hold(app.HeatmapAxes, 'off');
        end

        function score = computeFanScore(app, fanID, speed)
            % finds what fan is recommended to the gym owner as it 
            % checks which speed would be more valuable to maintain 
            % in such environment
            tr = app.TestRuns;
            idx = find(strcmp(tr.fan_id, fanID) & strcmp(tr.speed_setting, speed), 1);
            if isempty(idx)
                score = -Inf;
                return;
            end
            tID = tr.test_id{idx};

            pMask = strcmp(app.PowerConsumption.test_id, tID);
            meanPower = mean(app.PowerConsumption.power_W(pMask), 'omitnan');

            vMask = strcmp(app.AirVelocity.test_id, tID);
            meanAirSpeed = mean(app.AirVelocity.air_speed_mps(vMask), 'omitnan');

            tMask = strcmp(app.Temperature.test_id, tID);
            meanTemp = mean(app.Temperature.temperature_C(tMask), 'omitnan');

            if meanTemp >= app.OptimalLowC && meanTemp <= app.OptimalHighC
                tempPenalty = 0;
            else
                % if the average temp isn't in the comfort zone, then theirs a
                % penalty given, which lowers the score of being
                % recommended
                d = min(abs(meanTemp - app.OptimalLowC), abs(meanTemp - app.OptimalHighC));
                tempPenalty = d;
            end

            efficiency = meanAirSpeed / meanPower;
            % better efficiency means better score 
            score = (efficiency * 100) - (meanPower * 0.01) - (tempPenalty * 5);
            % equation to find the final score
        end

        function refreshSummary(app)
            % fills in tab 4 with the information 
            fd = app.FanDesigns;
            idx = find(strcmp(fd.fan_id, app.CurrentFanID), 1);

            avgTemp = app.currentAverageTemp();

            pMask = strcmp(app.PowerConsumption.test_id, app.CurrentTestID);
            meanPower = mean(app.PowerConsumption.power_W(pMask), 'omitnan');

            vMask = strcmp(app.AirVelocity.test_id, app.CurrentTestID);
            meanAirSpeed = mean(app.AirVelocity.air_speed_mps(vMask), 'omitnan');

            rMask = strcmp(app.RotationSpeed.test_id, app.CurrentTestID);
            meanRPM = mean(app.RotationSpeed.rpm(rMask), 'omitnan');

            efficiency = meanAirSpeed / meanPower;

            summary = sprintf([ ...
                'FAN: %s (%s)\n' ...
                'Speed Setting: %s | Avg RPM: %.0f\n\n' ...
                'Power Consumption: %.1f W\n' ...
                'Average Air Speed: %.2f m/s\n' ...
                'Efficiency: %.4f m/s per W\n' ...
                'Average Room Temperature: %.2f C (%.1f F)\n' ...
                'Optimal Comfort Band: %.1f-%.1f C\n'], ...
                app.CurrentFanID, fd.design_label{idx}, ...
                app.SpeedDropDown.Value, meanRPM, ...
                meanPower, meanAirSpeed, efficiency, ...
                avgTemp, avgTemp*9/5+32, app.OptimalLowC, app.OptimalHighC);

            app.SummaryTextArea.Value = summary;

            % recommendation for each fan across different speeds
            speed = app.SpeedDropDown.Value;
            fanIDs = fd.fan_id;
            scores = nan(numel(fanIDs), 1);
            for i = 1:numel(fanIDs)
                scores(i) = app.computeFanScore(fanIDs{i}, speed);
            end
            [~, bestIdx] = max(scores);
            bestFanID = fanIDs{bestIdx};
            bestLabel = fd.design_label{bestIdx};

            app.RecommendationLabel.Text = sprintf( ...
                'Recommended Fan (at %s speed): %s \x2013 %s', ...
                speed, bestFanID, bestLabel);
        end
    end

    methods (Access = private)

        function createComponents(app)
            app.UIFigure = uifigure('Name', 'Fluxion Aero', 'Position', [100 100 980 640]);

            app.TabGroup = uitabgroup(app.UIFigure, 'Position', [10 10 960 620]);

            % tab 1 ui + text box + dropdown
            app.Tab1 = uitab(app.TabGroup, 'Title', 'Fan Selection');

            uilabel(app.Tab1, 'Text', 'Blade Shape', 'Position', [40 540 120 22], 'FontWeight', 'bold');
            app.ShapeDropDown = uidropdown(app.Tab1, 'Items', {'flat','curved'}, ...
                'Position', [40 510 150 22], 'ValueChangedFcn', @(~,~) app.updateSelection());

            uilabel(app.Tab1, 'Text', 'Blade Length', 'Position', [220 540 120 22], 'FontWeight', 'bold');
            app.LengthDropDown = uidropdown(app.Tab1, 'Items', {'short','long'}, ...
                'Position', [220 510 150 22], 'ValueChangedFcn', @(~,~) app.updateSelection());

            uilabel(app.Tab1, 'Text', 'Pitch Angle', 'Position', [400 540 120 22], 'FontWeight', 'bold');
            app.PitchDropDown = uidropdown(app.Tab1, 'Items', {'low','high'}, ...
                'Position', [400 510 150 22], 'ValueChangedFcn', @(~,~) app.updateSelection());

            uilabel(app.Tab1, 'Text', 'Speed Setting', 'Position', [580 540 120 22], 'FontWeight', 'bold');
            app.SpeedDropDown = uidropdown(app.Tab1, 'Items', {'low','medium','high'}, ...
                'Position', [580 510 150 22], 'ValueChangedFcn', @(~,~) app.updateSelection());

            app.SelectedFanLabel = uilabel(app.Tab1, 'Text', 'Selected Fan: ', ...
                'Position', [40 460 500 24], 'FontWeight', 'bold', 'FontSize', 14);

            app.FanInfoTextArea = uitextarea(app.Tab1, 'Position', [40 260 500 180], ...
                'Editable', 'off');

            uilabel(app.Tab1, 'Text', ['Fluxion Aero helps you compare ceiling fan blade designs ' ...
                'for eco-friendly gyms. Choose a blade shape, length, and pitch angle to ' ...
                'select a fan design, then pick a speed setting. All other tabs update ' ...
                'automatically.'], 'Position', [40 60 860 150], 'WordWrap', 'on');

            % tab 2 ui
            app.Tab2 = uitab(app.TabGroup, 'Title', 'Performance');

            app.PowerAxes = uiaxes(app.Tab2, 'Position', [40 60 430 500]);
            app.EfficiencyAxes = uiaxes(app.Tab2, 'Position', [500 60 430 500]);

            % tab 3 ui
            app.Tab3 = uitab(app.TabGroup, 'Title', 'Temperature & Airflow');

            % ui/text for lamp, display for heatmap, while the toggle feature 
      
            statusPanel = uipanel(app.Tab3, 'Position', [20 520 900 70], ...
                'BorderType', 'line');

            app.TempLampLabel = uilabel(statusPanel, 'Text', 'Temperature Status: Close to Target', ...
                'Position', [20 36 300 22], 'FontWeight', 'bold');
            app.TempLamp = uilamp(statusPanel, 'Position', [280 34 26 26]);

            app.TempValueLabel = uilabel(statusPanel, 'Text', 'Average Room Temperature: ', ...
                'Position', [20 8 400 22]);

            uilabel(statusPanel, 'Text', 'Heatmap Metric', 'Position', [650 46 160 18], ...
                'FontWeight', 'bold', 'HorizontalAlignment', 'center');

            % toggle feature between the two heatmaps
            app.HeatmapMetricSwitch = uiswitch(statusPanel, 'slider', 'Position', [680 14 100 22], ...
                'Items', {'Air Speed','Temperature'}, 'Value', 'Air Speed', ...
                'ValueChangedFcn', @(~,~) app.refreshHeatmap());

            app.HeatmapAxes = uiaxes(app.Tab3, 'Position', [40 30 880 470]);

            % tab 4 - text 
            app.Tab4 = uitab(app.TabGroup, 'Title', 'Summary & Recommendation');

            uilabel(app.Tab4, 'Text', 'Data Summary', 'Position', [40 555 300 24], ...
                'FontWeight', 'bold', 'FontSize', 14);
            app.SummaryTextArea = uitextarea(app.Tab4, 'Position', [40 300 860 240], ...
                'Editable', 'off');

            app.RecommendationLabel = uilabel(app.Tab4, 'Text', 'Recommended Fan: ', ...
                'Position', [40 240 860 40], 'FontWeight', 'bold', 'FontSize', 14, ...
                'FontColor', [0.10 0.45 0.20], 'WordWrap', 'on');

            app.RecomputeButton = uibutton(app.Tab4, 'Text', 'Recompute Summary', ...
                'Position', [40 190 180 30], 'ButtonPushedFcn', @(~,~) app.refreshSummary());
        end
    end

    methods (Access = public)

        function app = FluxionAeroApp
            app.createComponents();
            app.loadAllData();

            % the default setting for the app when it first runs
            app.ShapeDropDown.Value = 'flat';
            app.LengthDropDown.Value = 'short';
            app.PitchDropDown.Value = 'low';
            app.SpeedDropDown.Value = 'low';
            app.updateSelection();

            if nargout == 0
                clear app
            end
        end

        function delete(app)
            delete(app.UIFigure);
        end
    end
end