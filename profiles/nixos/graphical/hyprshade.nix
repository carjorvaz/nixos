{
  config,
  lib,
  pkgs,
  ...
}:

{
  environment.systemPackages = with pkgs; [ hyprshade ];

  home-manager.users.cjv = {
    wayland.windowManager.hyprland = {
      settings = {
        exec = [
          # https://github.com/loqusion/hyprshade?tab=readme-ov-file#tips
          "${pkgs.hyprshade}/bin/hyprshade auto"
        ];

        exec-once = [
          # https://github.com/loqusion/hyprshade?tab=readme-ov-file#scheduling
          "${pkgs.dbus}/bin/dbus-update-activation-environment --systemd HYPRLAND_INSTANCE_SIGNATURE"
        ];

        bind = [
          # Grayscale toggle
          "$mainMod, G, exec, ${pkgs.hyprshade}/bin/hyprshade toggle grayscale"
        ];
      };
    };

    xdg.configFile = {
      "hypr/hyprshade.toml".text = ''
        [[shades]]
        name = "blue-light-filter"
        start_time = 19:00:00
        end_time = 06:00:00

        [[shades]]
        name = "grayscale"
      '';

      # Copied from: https://github.com/TheRiceCold/dots/blob/d25001db1529195174b214fe61e507522ea2195d/home/wolly/kaizen/desktop/wayland/hyprland/ecosystem/hyprshade.nix#L35C4-L50C8
      "hypr/shaders/grayscale.glsl".text = ''
        precision mediump float;
        varying vec2 v_texcoord;
        uniform sampler2D tex;

        void main() {
          vec4 pixColor = texture2D(tex, v_texcoord);

          gl_FragColor = vec4(
            pixColor[0] * 0.299 + pixColor[1] * 0.587 + pixColor[2] * 0.114,
            pixColor[0] * 0.299 + pixColor[1] * 0.587 + pixColor[2] * 0.114,
            pixColor[0] * 0.299 + pixColor[1] * 0.587 + pixColor[2] * 0.114,
            pixColor[3]
          );
        }
      '';

      # Edited from: https://github.com/loqusion/hyprshade/blob/main/shaders/blue-light-filter.glsl.mustache
      "hypr/shaders/blue-light-filter.glsl.mustache".text = ''
        /*
         * Blue Light Filter
         *
         * Use warmer colors to make the display easier on your eyes.
         *
         * Source: https://github.com/hyprwm/Hyprland/issues/1140#issuecomment-1335128437
         */

        precision highp float;
        varying vec2 v_texcoord;
        uniform sampler2D tex;

        /**
         * Color temperature in Kelvin.
         * https://en.wikipedia.org/wiki/Color_temperature
         *
         * @min 1000.0
         * @max 40000.0
         */
        const float Temperature = float({{#nc}}{{temperature}} ? 2000.0{{/nc}});

        /**
         * Strength of filter.
         *
         * @min 0.0
         * @max 1.0
         */
        const float Strength = float({{#nc}}{{strength}} ? 1.0{{/nc}});

        #define WithQuickAndDirtyLuminancePreservation
        const float LuminancePreservationFactor = 1.0;

        // function from https://www.shadertoy.com/view/4sc3D7
        // valid from 1000 to 40000 K (and additionally 0 for pure full white)
        vec3 colorTemperatureToRGB(const in float temperature) {
            // values from: http://blenderartists.org/forum/showthread.php?270332-OSL-Goodness&p=2268693&viewfull=1#post2268693
            mat3 m = (temperature <= 6500.0) ? mat3(vec3(0.0, -2902.1955373783176, -8257.7997278925690),
                                                    vec3(0.0, 1669.5803561666639, 2575.2827530017594),
                                                    vec3(1.0, 1.3302673723350029, 1.8993753891711275))
                                             : mat3(vec3(1745.0425298314172, 1216.6168361476490, -8257.7997278925690),
                                                    vec3(-2666.3474220535695, -2173.1012343082230, 2575.2827530017594),
                                                    vec3(0.55995389139931482, 0.70381203140554553, 1.8993753891711275));
            return mix(clamp(vec3(m[0] / (vec3(clamp(temperature, 1000.0, 40000.0)) + m[1]) + m[2]), vec3(0.0), vec3(1.0)),
                       vec3(1.0), smoothstep(1000.0, 0.0, temperature));
        }

        void main() {
            vec4 pixColor = texture2D(tex, v_texcoord);

            // RGB
            vec3 color = vec3(pixColor[0], pixColor[1], pixColor[2]);

        #ifdef WithQuickAndDirtyLuminancePreservation
            color *= mix(1.0, dot(color, vec3(0.2126, 0.7152, 0.0722)) / max(dot(color, vec3(0.2126, 0.7152, 0.0722)), 1e-5),
                         LuminancePreservationFactor);
        #endif

            color = mix(color, color * colorTemperatureToRGB(Temperature), Strength);

            vec4 outCol = vec4(color, pixColor[3]);

            gl_FragColor = outCol;
        }
      '';
    };
  };
}
