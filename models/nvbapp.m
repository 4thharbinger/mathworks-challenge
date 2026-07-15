load("fan_air_velocity.mat")
load("fan_power_consumption.mat")
load("fan_rotation_speed.mat")

tests = unique(string(air_velocity.test_id));
fans = unique(string(air_velocity.fan_id));
locations = unique(string(air_velocity.location_id));

test = tests(1);
fan = fans(1);
location = locations(1);

condition = air_velocity.test_id == test & ...
            air_velocity.fan_id == fan & ...
            air_velocity.location_id == location;

% hold off;
% plot( ...
%    air_velocity.time_min(condition), ...
%    air_velocity.air_speed_mps(condition));

function [by_trials] = reshape_by_trials(data, trials)
    by_trials = reshape(data, [], trials);
end

function out = round_length_to(data, n)
    out = data(1:end-mod(length(data), n));
end

function out = mean_every(data, n)
    out = mean(reshape(round_length_to(data, n), n, []), 1);
end

num_trials = length(tests);

power_by_trials = reshape_by_trials(power_consumption.power_W, num_trials);
voltage_by_trials = reshape_by_trials(power_consumption.voltage_V, num_trials);
current_by_trials = reshape_by_trials(power_consumption.current_A, num_trials);
rpm_by_trials = reshape_by_trials(rotation_speed.rpm, num_trials);
air_speed_by_trials = reshape_by_trials(air_velocity.air_speed_mps(air_velocity.location_id == "L01"), num_trials );

avg_power_by_trials = mean(power_by_trials, 1);
avg_power_by_fan = reshape(avg_power_by_trials, 3, []);

avg_speed_by_trials = mean(air_speed_by_trials, 1);
avg_speed_by_fan = reshape(avg_speed_by_trials, 3, []);

hold on
x = categorical(fans');
y = double(mean(avg_speed_by_fan ./ avg_power_by_fan, 1));
bar(x, y)
xlabel('Fan Design')
ylabel('Power / Flow (W / m/s)')
title('Fan Efficiency by design')
hold off